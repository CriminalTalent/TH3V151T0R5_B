# main.rb
$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_client'
require_relative 'battle_processor'
require_relative 'toot_builder'

OPS_SHEET_ID      = ENV['OPS_SHEET_ID']
RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
RUNNER_SHEET_URL  = ENV['RUNNER_SHEET_URL']
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
POLL_INTERVAL     = 30
PHASE_FILE        = File.join(__dir__, 'battle_phase.json')

def read_phase
  return nil unless File.exist?(PHASE_FILE)
  JSON.parse(File.read(PHASE_FILE), symbolize_names: true)
rescue
  nil
end

def write_phase(data)
  File.write(PHASE_FILE, JSON.pretty_generate(data))
end

def clear_phase
  File.delete(PHASE_FILE) if File.exist?(PHASE_FILE)
end

def announce_round(trigger, mastodon)
  round = trigger[:round]
  
  mastodon.post_public(
    "[#{round}라운드 시작]\n\n" \
    "A팀은 아래 시트에서 이동 좌표를 입력해주세요.\n" \
    "#{RUNNER_SHEET_URL}\n\n" \
    "이동 좌표: A1~H8 중 선택\n" \
    "크리쳐는 자동으로 공격합니다."
  )

  puts "[전투봇] #{round}라운드 알림 완료"
end

def settle_round(phase, ops_sheet, runner_sheet, creature_sheet, view_sheet, mastodon)
  round = phase[:round]
  puts "[전투봇] #{round}라운드 전체 정산 시작"

  base_stats = ops_sheet.read_base_stats
  a_commands = runner_sheet.read_runner_commands
  a_state    = runner_sheet.read_runner_state
  
  creature_config = creature_sheet.read_creature_config
  creature_name = creature_config&.dig(:name)
  
  unless creature_name
    puts "[전투봇 오류] 활성화된 크리쳐 없음"
    return
  end

  creature_base = creature_sheet.read_creature_stats(creature_name)
  unless creature_base
    puts "[전투봇 오류] 크리쳐 스탯 불러오기 실패: #{creature_name}"
    return
  end

  creature_state = { name: creature_name, hp: creature_base[:hp], pos: 'A1' }
  current_state = a_state + [creature_state]

  skill_data  = ops_sheet.read_skill_data
  corrections = ops_sheet.read_corrections
  cooldowns   = ops_sheet.read_cooldowns
  buffs_in    = ops_sheet.read_buffs

  puts "[전투봇] A팀 #{a_state.size}명 / 크리쳐 #{creature_name} / 커맨드 #{a_commands.size}개"

  processor = BattleProcessor.new(
    base_stats, current_state, a_commands, skill_data, creature_base,
    corrections, cooldowns, buffs_in, round
  )

  log, updated_states, updated_cooldowns, updated_buffs = processor.process

  ops_sheet.clear_corrections
  ops_sheet.write_cooldowns(updated_cooldowns)
  ops_sheet.write_buffs(updated_buffs)

  a_updated = updated_states.select { |name, _| a_state.any? { |s| s[:name] == name } }.values
  creature_updated = updated_states[creature_name]

  runner_sheet.update_runner_state(a_updated)
  creature_sheet.update_creature_state(creature_updated)
  view_sheet.update_view_map(a_updated + [creature_updated])
  view_sheet.update_view_team(a_updated, 'A팀')
  view_sheet.update_view_creature(creature_updated)

  puts "[전투봇] 현황 + 맵 + 쿨타임 + 버프 업데이트 완료"

  toots = TootBuilder.new(round, log).build
  puts "[전투봇] 툿 #{toots.size}개 생성"

  parent_id = nil
  toots.each_with_index do |text, i|
    sleep(1)
    parent_id = i == 0 ? mastodon.post_public(text) : mastodon.reply_public(text, parent_id)
  end

  clear_phase
  puts "[전투봇] #{round}라운드 전체 정산 완료"
end

def run_once(ops_sheet, runner_sheet, creature_sheet, view_sheet, mastodon)
  trigger = ops_sheet.read_trigger
  return unless trigger&.dig(:on)

  phase = read_phase

  if phase && phase[:status] == 'waiting_commands'
    ops_sheet.turn_off_trigger
    settle_round(phase, ops_sheet, runner_sheet, creature_sheet, view_sheet, mastodon)
  else
    announce_round(trigger, mastodon)
    write_phase({ round: trigger[:round], status: 'waiting_commands' })
  end
rescue => e
  puts "[전투봇 오류] #{e.class}: #{e.message}"
  puts e.backtrace.first(8)
end

puts "[전투봇] 시작"

ops_sheet      = SheetManager.new(OPS_SHEET_ID, CREDENTIALS_PATH)
runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
mastodon       = MastodonClient.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

loop do
  run_once(ops_sheet, runner_sheet, creature_sheet, view_sheet, mastodon)
  sleep(POLL_INTERVAL)
end
