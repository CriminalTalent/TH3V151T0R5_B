$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_client'
require_relative 'battle_processor'
require_relative 'toot_builder'

OPS_SHEET_ID     = ENV['OPS_SHEET_ID']
TEAM_A_SHEET_ID  = ENV['TEAM_A_SHEET_ID']
TEAM_B_SHEET_ID  = ENV['TEAM_B_SHEET_ID']
VIEW_SHEET_ID    = ENV['VIEW_SHEET_ID']
CREDENTIALS_PATH = File.join(__dir__, 'credentials.json')
POLL_INTERVAL    = 30
PHASE_FILE       = File.join(__dir__, 'battle_phase.json')

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

def team_order(first_team)
  first_team == 'A팀' ? ['A팀', 'B팀'] : ['B팀', 'A팀']
end

def announce_round(trigger, mastodon, ops_sheet)
  round = trigger[:round]
  first_team = trigger[:team]
  order = team_order(first_team)

  mastodon.post_public(
    "[ #{round}라운드 커맨드 입력 안내 ]\n" \
    "선공: #{order[0]}\n" \
    "후공: #{order[1]}\n\n" \
    "양 팀은 커맨드를 입력해주세요."
  )

  write_phase({
    round: round,
    first_team: order[0],
    second_team: order[1],
    status: 'waiting_commands'
  })

  ops_sheet.turn_off_trigger
  puts "[전투봇] #{round}라운드 알림 완료 — 선공 #{order[0]} / 후공 #{order[1]}"
end

def settle_round(phase, ops_sheet, team_sheets, view_sheet, mastodon)
  round = phase[:round]
  first_team = phase[:first_team]
  second_team = phase[:second_team]

  puts "[전투봇] #{round}라운드 전체 정산 시작 — #{first_team} → #{second_team}"

  base_stats = ops_sheet.read_base_stats

  a_state = team_sheets['A팀'].read_current_state('A팀')
  b_state = team_sheets['B팀'].read_current_state('B팀')
  current_state = a_state + b_state

  first_commands  = team_sheets[first_team].read_commands(first_team)
  second_commands = team_sheets[second_team].read_commands(second_team)
  commands = first_commands + second_commands

  skill_data  = ops_sheet.read_skill_data
  corrections = ops_sheet.read_corrections
  cooldowns   = ops_sheet.read_cooldowns
  buffs_in    = ops_sheet.read_buffs

  puts "[전투봇] 캐릭터 #{current_state.size}명 / 커맨드 #{commands.size}개 / 보정 #{corrections.size}개"
  commands.each { |cmd| puts "[전투봇 DEBUG] cmd=#{cmd.inspect}" }

  processor = BattleProcessor.new(
    base_stats, current_state, commands, skill_data,
    corrections, cooldowns, buffs_in, round, '전체'
  )

  log, updated_states, updated_cooldowns, updated_buffs = processor.process

  ops_sheet.clear_corrections
  ops_sheet.write_cooldowns(updated_cooldowns)
  ops_sheet.write_buffs(updated_buffs)

  state_list = updated_states.values.map do |s|
    base = base_stats.find { |b| b[:name] == s[:name] }
    s[:max_hp] = base ? base[:hp] : s[:hp]
    s
  end

  a_names = a_state.map { |s| s[:name] }
  b_names = b_state.map { |s| s[:name] }

  all_a = state_list.select { |s| a_names.include?(s[:name]) }
  all_b = state_list.select { |s| b_names.include?(s[:name]) }

  team_sheets['A팀'].update_current_state(all_a, 'A팀')
  team_sheets['B팀'].update_current_state(all_b, 'B팀')

  view_sheet.update_view_map(all_a + all_b)
  view_sheet.update_view_team(all_a, 'A팀')
  view_sheet.update_view_team(all_b, 'B팀')

  puts "[전투봇] 현황 + 맵 + 쿨타임 + 버프 업데이트 완료"

  toots = TootBuilder.new(round, "전체", true, log).build
  toots[0] = toots[0].sub("[#{round}라운드] 전체 (선공) 행동 정산", "[#{round}라운드 결과] #{first_team}(선공) / #{second_team}(후공)")

  puts "[전투봇] 툿 #{toots.size}개 생성"

  parent_id = nil
  toots.each_with_index do |text, i|
    sleep(1)
    parent_id = i == 0 ? mastodon.post_public(text) : mastodon.reply_public(text, parent_id)
  end

  clear_phase
  puts "[전투봇] #{round}라운드 전체 정산 완료"
end

def run_once(ops_sheet, team_sheets, view_sheet, mastodon)
  trigger = ops_sheet.read_trigger
  return unless trigger&.dig(:on)

  phase = read_phase

  if phase && phase[:status] == 'waiting_commands'
    ops_sheet.turn_off_trigger
    settle_round(phase, ops_sheet, team_sheets, view_sheet, mastodon)
  else
    announce_round(trigger, mastodon, ops_sheet)
  end
rescue => e
  puts "[전투봇 오류] #{e.class}: #{e.message}"
  puts e.backtrace.first(8)
end

puts "[전투봇] 시작"

ops_sheet  = SheetManager.new(OPS_SHEET_ID, CREDENTIALS_PATH)
team_a     = SheetManager.new(TEAM_A_SHEET_ID, CREDENTIALS_PATH)
team_b     = SheetManager.new(TEAM_B_SHEET_ID, CREDENTIALS_PATH)
view_sheet = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
mastodon   = MastodonClient.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

team_sheets = { 'A팀' => team_a, 'B팀' => team_b }

loop do
  run_once(ops_sheet, team_sheets, view_sheet, mastodon)
  sleep(POLL_INTERVAL)
end
