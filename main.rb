# main.rb
$stdout.sync = true
$stderr.sync = truerequire 'dotenv'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_client'
require_relative 'battle_processor'
require_relative 'toot_builder'

RUNNER_SHEET_ID  = ENV['RUNNER_SHEET_ID']   # 커맨드 시트 ID
OPS_SHEET_ID     = ENV['OPS_SHEET_ID']      # 운영(전투) 시트 ID
CREDENTIALS_PATH = File.join(__dir__, 'credentials.json')
POLL_INTERVAL    = 30  # 초

def run_once(runner_sheet, ops_sheet, mastodon)
  trigger = ops_sheet.read_trigger
  return unless trigger&.dig(:on)

  round = trigger[:round]
  turn  = trigger[:turn]
  puts "[전투봇] 트리거 감지 — #{round}라운드 #{turn}턴"

  # 즉시 OFF (중복 실행 방지)
  ops_sheet.turn_off_trigger

  # 데이터 읽기
  base_stats    = runner_sheet.read_base_stats
  current_state = runner_sheet.read_current_state
  commands      = runner_sheet.read_commands
  skill_data    = runner_sheet.read_skill_data
  corrections   = ops_sheet.read_corrections

  puts "[전투봇] 캐릭터 #{current_state.size}명 / 커맨드 #{commands.size}개 / 보정 #{corrections.size}개"

  # 전투 계산
  processor = BattleProcessor.new(base_stats, current_state, commands, skill_data, corrections, round, turn)
  log, updated_states = processor.process

  # 보정 항목 적용 완료 처리
  ops_sheet.clear_corrections

  # 현상태 시트 업데이트
  state_list = updated_states.values
  runner_sheet.update_current_state(state_list)
  puts "[전투봇] 현상태 시트 업데이트 완료"

  # 툿 생성 및 전송
  toots = TootBuilder.new(round, turn, log).build
  puts "[전투봇] 툿 #{toots.size}개 생성"

  parent_id = nil
  toots.each_with_index do |text, i|
    sleep(1)
    if i == 0
      parent_id = mastodon.post_public(text)
    else
      parent_id = mastodon.reply_public(text, parent_id) if parent_id
    end
  end

  puts "[전투봇] 전송 완료"
rescue => e
  puts "[전투봇 오류] #{e.message}"
  puts e.backtrace.first(5)
end

puts "[전투봇] 시작"

runner_sheet = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
ops_sheet    = SheetManager.new(OPS_SHEET_ID, CREDENTIALS_PATH)
mastodon     = MastodonClient.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

loop do
  run_once(runner_sheet, ops_sheet, mastodon)
  sleep(POLL_INTERVAL)
end

require 'dotenv/load'
require 'set'
require 'time'

require_relative 'mastodon_client'
require_relative 'sheet_manager'
require_relative 'command_parser'
require_relative 'core/battle_engine'

# ---------------------------------
# ENV 체크 (너 지금 쓰는 키 기준)
# ---------------------------------
required = %w[
  GOOGLE_SHEET_ID
  GOOGLE_CREDENTIALS_PATH
  MASTODON_BASE_URL
  MASTODON_TOKEN
]
missing = required.select { |k| ENV[k].nil? || ENV[k].to_s.strip.empty? }

if missing.any?
  puts "[오류] 환경변수 누락: #{missing.join(' / ')}"
  exit 1
end

SHEET_ID = ENV['GOOGLE_SHEET_ID'].to_s.strip
CREDENTIALS_PATH = ENV['GOOGLE_CREDENTIALS_PATH'].to_s.strip

BASE_URL = ENV['MASTODON_BASE_URL'].to_s.strip
TOKEN    = ENV['MASTODON_TOKEN'].to_s.strip

# https:// 빠진 경우 방어
unless BASE_URL.start_with?('http://', 'https://')
  BASE_URL = "https://#{BASE_URL}"
end

BOT_START_TIME = Time.now
puts "[전투봇] 실행 시작 (#{BOT_START_TIME.strftime('%H:%M:%S')})"

# ---------------------------------
# Sheets 연결
# ---------------------------------
begin
  sheet_manager = SheetManager.new(SHEET_ID, CREDENTIALS_PATH)
  puts "Google Sheets 연결 성공"
rescue => e
  puts "[Google Sheets 연결 실패] #{e.message}"
  exit 1
end

# ---------------------------------
# Mastodon 연결 + 계정 확인
# ---------------------------------
mastodon = MastodonClient.new(base_url: BASE_URL, token: TOKEN)

begin
  acct = mastodon.verify_credentials
  puts "[마스토돈] 계정: @#{acct}"
rescue => e
  puts "[마스토돈] 계정 확인 실패: #{e.class}: #{e.message}"
  exit 1
end

# ---------------------------------
# 엔진 / 파서
# ---------------------------------
battle_engine = BattleEngine.new(mastodon, sheet_manager)
parser = CommandParser.new(mastodon, battle_engine)
puts "[파서] 초기화 완료"
puts "멘션 스트리밍 시작..."

processed = Set.new
MAX_SSL_RETRY = 3
MAX_GENERAL_RETRY = 3
ssl_error_count = 0
general_retry_count = 0

loop do
  begin
    puts "[마스토돈] user 스트림 구독 시작..."

    mastodon.stream_user do |status|
      begin
        # ✅ 가장 중요: status가 Hash가 아니면 스킵 (TypeError 방지)
        unless status.is_a?(Hash)
          puts "[스트리밍] 비정상 status 타입 스킵: #{status.class}"
          next
        end

        ssl_error_count = 0
        general_retry_count = 0

        mention_id = status[:id]
        next if mention_id.nil?
        next if processed.include?(mention_id)

        created_at = status[:created_at]
        if created_at
          created = Time.parse(created_at.to_s) rescue nil
          next if created && created < BOT_START_TIME
        end

        processed.add(mention_id)

        sender = status.dig(:account, :acct) || "unknown"
        puts "[스트리밍] #{mention_id} - @#{sender}"

        parser.parse(status)

      rescue => e
        puts "[에러] 멘션 처리 오류: #{e.class}: #{e.message}"
        puts e.backtrace.first(8)
      end
    end

  rescue EOFError, OpenSSL::SSL::SSLError => e
    ssl_error_count += 1
    puts "[SSL 오류 #{ssl_error_count}/#{MAX_SSL_RETRY}] #{e.message}"

    sleep(ssl_error_count >= MAX_SSL_RETRY ? 30 : 3)
    retry

  rescue Interrupt
    puts "\n[종료] 봇을 종료합니다..."
    break

  rescue SystemExit, SignalException
    puts "\n[종료] 시스템 종료 시그널 수신..."
    break

  rescue => e
    general_retry_count += 1
    puts "[스트리밍 오류 #{general_retry_count}/#{MAX_GENERAL_RETRY}] #{e.class}: #{e.message}"
    puts e.backtrace.first(8)

    sleep(general_retry_count >= MAX_GENERAL_RETRY ? 60 : 5)
    retry
  end
end

puts "[종료] 전투봇이 정상적으로 종료되었습니다."
