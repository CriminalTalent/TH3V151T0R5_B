# main.rb (마스토돈 커맨드 방식)
$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_client'
require_relative 'battle_processor'
require_relative 'toot_builder'
require_relative 'state_manager'

RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
POLL_INTERVAL     = 30

def setup_battle(round, mastodon, runner_sheet)
  base_stats = runner_sheet.read_runner_stats
  skill_data = runner_sheet.read_skill_data

  a_state = runner_sheet.read_runner_state
  
  mastodon.post_public(
    "[#{round}라운드 시작]\n\n" \
    "A팀은 자동봇 시트의 그리드에 자신의 이름을 입력해주세요.\n" \
    "위치: A1~H8 중 선택\n" \
    "크리쳐는 자동으로 공격합니다."
  )

  {
    round: round,
    status: 'waiting_commands',
    base_stats: base_stats,
    skill_data: skill_data,
    runner_state: a_state
  }
end

def settle_battle(state, mastodon, runner_sheet, creature_sheet, view_sheet, state_mgr)
  round = state[:round]
  puts "[전투봇] #{round}라운드 전체 정산 시작"

  base_stats = state[:base_stats]
  skill_data = state[:skill_data]
  a_state = runner_sheet.read_runner_state
  
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

  a_commands = a_state.map do |s|
    {
      name:       s[:name],
      move_to:    s[:pos],
      action:     '이동',
      targets:    [],
      target_pos: '',
      extra:      ''
    }
  end

  cooldowns = state_mgr.read_cooldowns
  buffs_in  = state_mgr.read_buffs
  corrections = []

  puts "[전투봇] A팀 #{a_state.size}명 / 크리쳐 #{creature_name}"

  processor = BattleProcessor.new(
    base_stats, current_state, a_commands, skill_data, creature_base,
    corrections, cooldowns, buffs_in, round
  )

  log, updated_states, updated_cooldowns, updated_buffs = processor.process

  state_mgr.write_cooldowns(updated_cooldowns)
  state_mgr.write_buffs(updated_buffs)

  a_updated = updated_states.select { |name,
