# main.rb (전체 재작성)
$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
require 'time'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_listener'
require_relative 'battle_processor'
require_relative 'toot_builder'

RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
ACTION_TIMEOUT    = 300

def start_battle(round, runner_sheet, creature_sheet, mastodon, listener)
  puts "[전투봇] #{round}라운드 시작"

  base_stats = runner_sheet.read_base_stats
  skill_data = runner_sheet.read_skill_data
  a_state = runner_sheet.read_runner_state
  
  creature_config = creature_sheet.read_creature_config
  unless creature_config
    puts "[전투봇 오류] 활성화된 크리쳐 없음"
    return nil
  end

  creature_base = creature_sheet.read_creature_stats(creature_config[:name])
  unless creature_base
    puts "[전투봇 오류] 크리쳐 스탯 불러오기 실패"
    return nil
  end

  creature_sheet.write_battle_state(round, 'waiting_actions')

  runner_tags = a_state.map { |s| "@#{s[:name]}" }.join(" ")
  mastodon.post_public(
    "[#{round}라운드 시작]\n\n" \
    "#{runner_tags}\n\n" \
    "DM으로 행동을 입력해주세요.\n" \
    "[공격/(크리쳐 이름)]\n" \
    "[회복/(아군이름)]\n" \
    "[방어/(아군이름)]\n" \
    "[스킬/(스킬명)]\n" \
    "[이동/(좌표)]\n\n" \
    "입력 대기: 5분"
  )

  {
    round: round,
    base_stats: base_stats,
    skill_data: skill_data,
    runner_state: a_state,
    creature_base: creature_base,
    creature_name: creature_config[:name],
    started_at: Time.now
  }
end

def collect_actions(battle_state, mastodon)
  round = battle_state[:round]
  started_at = battle_state[:started_at]
  runner_state = battle_state[:runner_state]

  actions = {}
  runner_state.each do |r|
    actions[r[:name]] = {
      action: '',
      target: ''
    }
  end

  end_time = started_at + ACTION_TIMEOUT

  while Time.now < end_time
    remaining = (end_time - Time.now).ceil
    puts "[전투봇] 행동 입력 대기... #{remaining}초"
    sleep(10)
  end

  puts "[전투봇] 5분 경과, 자동 정산 시작"
  actions
end

def settle_battle(battle_state, actions, runner_sheet, creature_sheet, view_sheet, mastodon)
  round = battle_state[:round]
  base_stats = battle_state[:base_stats]
  skill_data = battle_state[:skill_data]
  a_state = battle_state[:runner_state]
  creature_base = battle_state[:creature_base]
  creature_name = battle_state[:creature_name]

  puts "[전투봇] #{round}라운드 전체 정산 시작"

  creature_state = { name: creature_name, hp: creature_base[:hp], pos: 'A1' }
  current_state = a_state + [creature_state]

  a_commands = a_state.map do |s|
    action = actions[s[:name]] || { action: '', target: '' }
    {
      name:       s[:name],
      move_to:    extract_coordinate(action[:target]),
      action:     action[:action],
      targets:    [action[:target]].compact,
      target_pos: extract_coordinate(action[:target]),
      extra:      ''
    }
  end

  cooldowns = creature_sheet.read_cooldowns
  buffs_in  = creature_sheet.read_buffs
  corrections = []

  processor = BattleProcessor.new(
    base_stats, current_state, a_commands, skill_data, creature_base,
    corrections, cooldowns, buffs_in, round
  )

  log, updated_states, updated_cooldowns, updated_buffs = processor.process

  creature_sheet.write_cooldowns(updated_cooldowns)
  creature_sheet.write_buffs(updated_buffs)

  a_updated = updated_states.select { |name, _| a_state.any? { |s| s[:name] == name } }.values
  creature_updated = updated_states[creature_name]

  runner_sheet.update_runner_state(a_updated)
  creature_sheet.update_creature_state(creature_updated)
  view_sheet.update_view_map(a_updated + [creature_updated])
  view_sheet.update_view_team(a_updated, 'A팀')
  view_sheet.update_view_creature(creature_updated)

  puts "[전투봇] 현황 + 맵 업데이트 완료"

  toots = TootBuilder.new(round, log).build
  puts "[전투봇] 툿 #{toots.size}개 생성"

  parent_id = nil
  toots.each_with_index do |text, i|
    sleep(1)
    parent_id = i == 0 ? mastodon.post_public(text) : mastodon.reply_public(text, parent_id)
  end

  creature_sheet.write_battle_state(round, 'completed')
  puts "[전투봇] #{round}라운드 전체 정산 완료"
end

def extract_coordinate(text)
  return '' unless text
  match = text.match(/([A-H][1-8])/)
  match ? match[1] : ''
end

puts "[전투봇] 시작"

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

account_info = listener.get_account_info
gm_account_id = account_info['id'] if account_info

battle_state = nil
poll_interval = 30

loop do
  begin
    notifications = listener.get_notifications
    
    notifications.each do |notif|
      next unless notif['type'] == 'mention'
      next if notif['account']['id'].to_s == gm_account_id.to_s

      content = notif['status']['content']
      
      if content.include?('[전투시작]')
        round = content.match(/\[(\d+)\]/)&.[](1)&.to_i || 1
        battle_state = start_battle(round, runner_sheet, creature_sheet, listener, listener)
        
      elsif content.include?('[전투종료]')
        if battle_state
          creature_sheet.write_battle_state(0, 'terminated')
          listener.post_public("[전투 강제 종료]\n\n모든 전투가 종료되었습니다.")
          battle_state = nil
        end
        
      elsif battle_state && battle_state[:status] == 'waiting_actions'
        if content.match?(/\[(공격|회복|방어|스킬|이동)\/(.+)\]/)
          match = content.match(/\[(공격|회복|방어|스킬|이동)\/(.+)\]/)
          action_type = match[1]
          action_target = match[2]
          
          # DM으로 받은 행동 저장
          puts "[전투봇] #{notif['account']['username']} → [#{action_type}/#{action_target}]"
        end
      end
    end

    if battle_state
      if (Time.now - battle_state[:started_at]) > ACTION_TIMEOUT
        actions = {}
        battle_state[:runner_state].each { |r| actions[r[:name]] = { action: '', target: '' } }
        settle_battle(battle_state, actions, runner_sheet, creature_sheet, view_sheet, listener)
        battle_state = nil
      end
    end

  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
  end

  sleep(poll_interval)
end
