$stdout.sync = true
$stderr.sync = true

require 'dotenv'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_client'
require_relative 'battle_processor'
require_relative 'toot_builder'

RUNNER_SHEET_ID  = ENV['RUNNER_SHEET_ID']
OPS_SHEET_ID     = ENV['OPS_SHEET_ID']
CREDENTIALS_PATH = File.join(__dir__, 'credentials.json')
POLL_INTERVAL    = 30

def run_once(runner_sheet, ops_sheet, mastodon)
  trigger = ops_sheet.read_trigger
  return unless trigger&.dig(:on)

  round = trigger[:round]
  turn  = trigger[:turn]
  puts "[전투봇] 트리거 감지 — #{round}라운드 #{turn}턴"

  ops_sheet.turn_off_trigger

  base_stats    = ops_sheet.read_base_stats
  current_state = runner_sheet.read_current_state
  commands      = runner_sheet.read_commands
  skill_data    = ops_sheet.read_skill_data
  corrections   = ops_sheet.read_corrections

  puts "[전투봇] 캐릭터 #{current_state.size}명 / 커맨드 #{commands.size}개 / 보정 #{corrections.size}개"

  processor = BattleProcessor.new(base_stats, current_state, commands, skill_data, corrections, round, turn)
  log, updated_states = processor.process

  ops_sheet.clear_corrections

  state_list = updated_states.values
  runner_sheet.update_current_state(state_list)
  puts "[전투봇] 현상태 업데이트 완료"

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
