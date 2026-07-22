$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
require 'time'
require 'net/http'
require 'uri'
require 'set'

Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_listener'
require_relative 'battle_calculator'
require_relative 'battle_util'
require_relative 'battle_api'
require_relative 'battle_state'
require_relative 'battle_grid'
require_relative 'battle_skills'
require_relative 'battle_boss_patterns'
require_relative 'battle_round'
require_relative 'battle_session'

RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
TRIGGER_SHEET_ID  = '1FIvnRTLlcDmx29TShi7XnX9uGYuEc-YC63B9b4Z1IHE'
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
BOT_USERNAME      = ENV['BOT_USERNAME'] || 'DOWN'

ROUND_WAIT_SECONDS = 60
ACTION_WAIT_SECONDS = 300
TRIGGER_CHECK_INTERVAL = 15
POST_INTERVAL_SECONDS = 1.5

LOCATION_MAP = {
  '스토디시' => 'E7',
  'A' => 'A1', 'B' => 'B1', 'C' => 'C1', 'D' => 'D1',
  'E' => 'E1', 'F' => 'F1', 'G' => 'G1'
}

puts '[전투봇] 시작'

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

$trigger_sheet = SheetManager.new(TRIGGER_SHEET_ID, CREDENTIALS_PATH)

puts '[전투봇] 초기화 완료 - 다중 전투 세션 모드'

processed_statuses = Set.new
processed_dm_ids = Set.new
processed_notification_ids = Set.new
processed_action_status_ids = Set.new
handled_boss_status_ids = Set.new
held_boss_logged_ids = Set.new
handled_battle_end_status_ids = Set.new
sessions = {}
last_post_time = Time.at(0)

def create_battle_session_from_status(status, content, mode, creature_sheet, bot_username, fallback_sender = nil)
  usernames = extract_usernames_from_status(status, content, bot_username)
  usernames = usernames.map { |u| u.to_s.gsub('@', '').strip }.reject(&:empty?).uniq

  if usernames.empty? && fallback_sender
    usernames = [fallback_sender.to_s.gsub('@', '').strip]
  end

  return nil if usernames.empty?

  creature = creature_from_start_content(content, creature_sheet)
  creature[:pos] = 'D4' if creature[:pos].to_s.strip.empty?

  session = BattleSession.new(
    id: status['id'],
    mode: mode,
    runner_names: usernames,
    creature: creature.dup,
    thread_reply_id: status['id'],
    round: content.match(/\[(\d+)\]/)&.[](1) || 1
  )
  session.thread_ids ||= Set.new
  session.thread_ids.add(status['id'].to_s)
  session.auto_mode = false
  session
end

def post_session_thread(session, text, last_post_time)
  dm = ($trigger_sheet.read_visibility != 'public')
  now = Time.now
  sleep_time = POST_INTERVAL_SECONDS - (now - last_post_time)
  sleep(sleep_time) if sleep_time > 0
  
  response = post_battle_thread(text, dm, session.thread_reply_id)
  if response && response['id']
    session.mark_thread_id(response['id'])
    session.thread_ids ||= Set.new
    session.thread_ids.add(response['id'].to_s)
  end
  [response, Time.now]
end

def sheet_log(creature_sheet, session_id, round, event, detail)
  return unless creature_sheet
  time = Time.now.strftime('%Y-%m-%d %H:%M:%S')
  creature_sheet.append_battle_log([time, session_id.to_s, round.to_s, event.to_s, detail.to_s])
rescue => e
  puts "[전투로그 기록 실패] #{e.class}: #{e.message}"
end

def battle_start_text?(text)
  text.to_s.include?('[전투시작]') || text.to_s.match?(/\[전투시작\//)
end

def battle_end_text?(text)
  text = text.to_s
  text.include?('[전투종료]') ||
    text.include?('[전투중단]') ||
    text.include?('[전투강제종료]') ||
    text.include?('[전투취소]') ||
    text.include?('[전투 종료]') ||
    text.include?('[전투 중단]')
end

def announce_prep_round(session, view_sheet, runner_sheet, last_post_time)
  ctx = session.passive_ctx
  ctx[:positions] ||= {}

  state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
  ctx[:prep_required] = state.select { |r| r[:hp].to_i > 0 }.map { |r| r[:name].to_s }
  session.mark_dead_runners(state.select { |r| r[:hp].to_i <= 0 }.map { |r| r[:name].to_s })

  map_lines = BattleGrid.render([], session.creature)

  announcement = "#{session.runner_tags}\n\n" \
                 "[준비 라운드] #{session.creature[:name]}와의 전투!\n" \
                 "#{session.creature[:name]} 상태: #{view_sheet.health_bar(session.creature[:hp], session.creature[:max_hp])} (위치: #{session.creature[:pos]}, 크기: #{session.creature[:size] || '1x1'} 방향: #{session.creature[:facing] || '하'})\n\n" \
                 "점유칸: #{BattleGrid.creature_cells(session.creature).join(
                 "전장\n\n" \
                 "#{map_lines.join("\n")}\n" \
                 "───────────────────\n" \
                 "DM 또는 멘션으로 시작 위치를 입력해주세요.\n\n" \
                 "형식: [좌표]\n" \
                 "입력 대기: 5분\n" \
                 "───────────────────"

  response, new_time = post_session_thread(session, announcement, last_post_time)
  if response && response['id']
    session.announced = true
    session.phase = :prep
    puts "[전투봇] [세션 #{session.id}] 준비 라운드 안내 송출"
  else
    session.announced = false
    session.phase = :prep
    puts "[전투봇] [세션 #{session.id}] 준비 라운드 안내 송출 실패"
  end
  new_time
end

def handle_prep_input(session, username, text, processed_set, processed_id, listener, global_set = nil, status_id = nil)
  processed_set.add(processed_id)

  sid = (status_id || processed_id).to_s
  return if global_set && global_set.include?(sid)

  m = text.to_s.match(/\[([A-Ga-g][1-8])\]/)
  return unless m

  global_set.add(sid) if global_set

  pos = m[1].upcase
  if BattleGrid.creature_cells(session.creature).include?(pos)
    listener.send_dm(username, "#{pos}은(는) #{session.creature[:name]}이(가) 점유한 칸입니다. 다른 좌표를 입력 해주세요.")
    return
  end

  (session.passive_ctx[:positions] ||= {})[username.to_s] = pos
  puts "[전투봇] [세션 #{session.id}] 시작 위치 등록: @#{username} → #{pos}"
end

def check_prep_completion(session, creature_sheet = nil)
  return unless session.active && session.phase == :prep && session.announced

  ctx = session.passive_ctx
  required  = (ctx[:prep_required] || session.runner_names).map(&:to_s)
  positions = ctx[:positions] || {}

  all_set = required.any? && required.all? { |name| positions[name].to_s.match?(/\A[A-G][1-8]\z/) }
  timeout = (Time.now - session.start_time) >= ACTION_WAIT_SECONDS
  return unless all_set || timeout

  session.awaiting_boss = false
  session.phase = :announcing
  ctx[:boss_override] = { skill: '전체공격' }
  session.announced = false
  session.actions = {}
  session.processed_messages = {}
  session.start_time = Time.now
  puts "[전투봇] [세션 #{session.id}] 준비 라운드 완료 - #{session.round}라운드 시작 (보스 행동: 전체공격 고정)"
  positions_text = positions.map { |k, v| "#{k}→#{v}" }.join(', ')
  sheet_log(creature_sheet, session.id, session.round, '준비 라운드 완료',
            "시작 위치: #{positions_text} / #{session.round}라운드 시작 (보스 행동: 전체공격 고정)")
end

def boss_command_text?(text)
  text.to_s.match?(/\[보스행동커맨드\//)
end

def try_boss_command!(sessions, sender, status, text, creature_sheet, quiet_hold: false)
  sender_clean = sender.to_s.gsub('@', '').strip
  return :pass if sender_clean.empty?
  return :pass if defined?(BOT_USERNAME) && sender_clean == BOT_USERNAME.to_s.gsub('@', '').strip
  return :pass if sessions.values.any? { |s| s.includes_runner?(sender_clean) }

  skill = nil
  args  = nil

  if (m = text.to_s.match(/\[보스행동커맨드\/([^\]]+)\]/))
    args = m[1]
  elsif (m = text.to_s.match(/\[([^\/\]]+)(?:\/([^\]]+))?\]/))
    cand = m[1].to_s.strip
    return :pass unless boss_skill_defined?(creature_sheet, cand)
    skill = cand
    args = m[2]
  else
    return :pass
  end

  status_id = status['id'].to_s
  if status && status['in_reply_to_id']
    root_or_thread_id = status['in_reply_to_id'].to_s
    candidate_sessions = sessions.values.select do |s|
      s.awaiting_boss && (s.id.to_s == root_or_thread_id || s.thread_ids.to_a.include?(root_or_thread_id))
    end
    
    if candidate_sessions.length == 1
      session = candidate_sessions.first
    elsif candidate_sessions.length > 1
      unless quiet_hold
        puts "[전투봇] 보스행동커맨드 보류: 타래 연결이 모호함 (#{candidate_sessions.length}개 세션 매치, 자동 재시도)"
        sheet_log(creature_sheet, '-', '-', '보스행동커맨드 보류', "@#{sender_clean}: #{text.to_s.strip} (타래 모호, 자동 재시도)")
      end
      return :hold
    else
      active_waiting = sessions.values.select(&:awaiting_boss)
      if active_waiting.length == 1
        session = active_waiting.first
      elsif active_waiting.length > 1
        unless quiet_hold
          puts "[전투봇] 보스행동커맨드 보류: 타래 미연결 + 대기 세션 여럿 (자동 재시도)"
          sheet_log(creature_sheet, '-', '-', '보스행동커맨드 보류', "@#{sender_clean}: #{text.to_s.strip} (타래 미연결, 대기 세션 #{active_waiting.length}개, 자동 재시도)")
        end
        return :hold
      else
        puts "[전투봇] 보스행동커맨드 무시: 대기 중인 세션 없음"
        sheet_log(creature_sheet, '-', '-', '보스행동커맨드 무시', "@#{sender_clean}: #{text.to_s.strip} (대기 중인 세션 없음)")
        return :ignored
      end
    end
  else
    active_waiting = sessions.values.select(&:awaiting_boss)
    if active_waiting.length == 1
      session = active_waiting.first
    elsif active_waiting.length > 1
      unless quiet_hold
        puts "[전투봇] 보스행동커맨드 보류: 타래 미연결 + 대기 세션 여럿 (자동 재시도)"
        sheet_log(creature_sheet, '-', '-', '보스행동커맨드 보류', "@#{sender_clean}: #{text.to_s.strip} (타래 미연결, 대기 세션 #{active_waiting.length}개, 자동 재시도)")
      end
      return :hold
    else
      puts "[전투봇] 보스행동커맨드 무시: 대기 중인 세션 없음"
      sheet_log(creature_sheet, '-', '-', '보스행동커맨드 무시', "@#{sender_clean}: #{text.to_s.strip} (대기 중인 세션 없음)")
      return :ignored
    end
  end

  tokens = args.to_s.split(%r{[\/,]}).map(&:strip).reject(&:empty?)

  if skill.nil? && tokens.any? && boss_skill_defined?(creature_sheet, tokens.first)
    skill = tokens.shift
  end

  cells = tokens.select { |t| t.match?(/\A[A-Ga-g][1-8]\z/) }.map(&:upcase)

  if cells.any? && cells.size == tokens.size
    active_count = sessions.values.count { |s| s.active && s.awaiting_boss && s.id != session.id }
    if cells.any? || skill == '전체공격'
      if active_count > 0
        puts "[전투봇] 보스행동커맨드 거부: 좌표/전체공격은 활성 세션이 유일할 때만 허용됨"
        sheet_log(creature_sheet, session.id, session.round, '보스행동커맨드 거부', "@#{sender_clean}: 좌표/전체공격 (다른 활성 세션 존재)")
        return :ignored
      end
    end
  end

  override = {}
  override[:skill] = skill if skill
  if cells.any? && cells.size == tokens.size
    override[:cells] = cells
  elsif tokens.any?
    targets_clean = tokens.map { |t| t.gsub('@', '').strip }
    state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
    begin
      base_stats = runner_sheet.read_base_stats
    rescue
      base_stats = []
    end
    state.each do |r|
      stat = base_stats.find { |b| b[:name].to_s == r[:name].to_s }
      label = stat ? stat[:display_name].to_s.strip : ''
      r[:display_name] = label.empty? ? r[:name].to_s : label
    end

    invalid_targets = targets_clean.reject do |t|
      state.any? { |r| r[:name].to_s == t || r[:display_name].to_s == t || r[:display_name].to_s.gsub(/\s+/, '') == t.gsub(/\s+/, '') }
    end

    if invalid_targets.any?
      puts "[전투봇] [세션 #{session.id}] 보스행동커맨드 거부: 세션 외 대상 #{invalid_targets.join(', ')}"
      sheet_log(creature_sheet, session.id, session.round, '보스행동커맨드 거부', "@#{sender_clean}: 세션 외 대상 #{invalid_targets.join(', ')}")
      return :ignored
    end

    mapped = targets_clean.map do |t|
      found = state.find do |r|
        r[:name].to_s == t ||
          r[:display_name].to_s == t ||
          r[:display_name].to_s.gsub(/\s+/, '') == t.gsub(/\s+/, '')
      end
      found ? found[:name].to_s : t
    end
    override[:targets] = mapped
  end

  if override.empty?
    puts '[전투봇] 보스행동커맨드 무시: 스킬/대상 없음'
    sheet_log(creature_sheet, session.id, session.round, '보스행동커맨드 무시', "@#{sender_clean}: #{text.to_s.strip} (스킬/대상 없음)")
    return :ignored
  end

  session.passive_ctx[:boss_override] = override
  session.awaiting_boss = false
  session.phase = :announcing
  session.announced = false
  session.actions = {}
  session.processed_messages = {}
  session.start_time = Time.now
  desc = [skill, tokens.join(', ')].compact.reject { |v| v.to_s.empty? }.join(' / ')
  puts "[전투봇] [세션 #{session.id}] 보스행동커맨드 적용 (@#{sender_clean}) → #{desc} / #{session.round}라운드"
  sheet_log(creature_sheet, session.id, session.round, '보스행동커맨드 적용', "@#{sender_clean} → #{desc} / status=#{status_id}")
  :applied
end

def announce_boss_turn(session, view_sheet, runner_sheet, last_post_time)
  ctx = session.passive_ctx
  positions = (ctx[:positions] ||= {})

  state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
  begin
    base_stats = runner_sheet.read_base_stats
  rescue
    base_stats = []
  end
  state.each do |r|
    pos = positions[r[:name].to_s].to_s.upcase
    r[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
    stat = base_stats.find { |b| b[:name].to_s == r[:name].to_s }
    label = stat ? stat[:display_name].to_s.strip : ''
    r[:display_name] = label.empty? ? r[:name].to_s : label
  end

  alive_for_map = state.select { |r| r[:hp].to_i > 0 }
  map_lines = BattleGrid.render(alive_for_map, session.creature)

  announcement = "#{session.runner_tags}\n\n" \
                 "[#{session.round}라운드] #{session.creature[:name]}와의 전투 - 보스 턴\n" \
                 "#{session.creature[:name]} 상태: #{view_sheet.health_bar(session.creature[:hp], session.creature[:max_hp])} (위치: #{session.creature[:pos]}, 크기: #{session.creature[:size] || '1x1'} 방향: #{session.creature[:facing] || '하'})\n\n" \
                 "점유칸: #{BattleGrid.creature_cells(session.creature).join(
                 "전장\n\n" \
                 "#{map_lines.join("\n")}\n" \
                 "───────────────────\n" \
                 "#{session.creature[:name]}이(가) 다음 행동을 준비하고 있습니다.\n" \
                 "운영 계정의 보스 행동 입력 대기 중\n" \
                 "───────────────────"

  response, new_time = post_session_thread(session, announcement, last_post_time)
  if response && response['id']
    session.announced = true
    session.phase = :boss_command
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 보스 턴 안내 송출"
  else
    session.announced = false
    session.phase = :boss_command
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 보스 턴 안내 송출 실패"
  end
  new_time
end

def announce_round(session, view_sheet, creature_sheet, runner_sheet, last_post_time)
  ctx = session.passive_ctx
  positions = (ctx[:positions] ||= {})

  state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
  begin
    base_stats = runner_sheet.read_base_stats
  rescue
    base_stats = []
  end
  state.each do |r|
    pos = positions[r[:name].to_s].to_s.upcase
    r[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
    stat = base_stats.find { |b| b[:name].to_s == r[:name].to_s }
    label = stat ? stat[:display_name].to_s.strip : ''
    r[:display_name] = label.empty? ? r[:name].to_s : label
  end
  session.mark_dead_runners(state.select { |r| r[:hp].to_i <= 0 }.map { |r| r[:name].to_s })

  refresh_creature_skill!(session.creature, creature_sheet)
  creature = session.creature

  override = ctx.delete(:boss_override)
  if override.is_a?(Hash)
    if override[:skill].to_s.strip != ''
      creature[:current_skill] = override[:skill].to_s.strip
      creature[:pattern]       = creature[:current_skill]
      apply_boss_skill_definition!(creature, creature_sheet)
    end
    if override[:cells].to_a.any?
      creature[:skill_range]   = override[:cells].join(',')
      creature[:pattern_cells] = override[:cells].join(',')
      creature[:skill_target]  = ''
    elsif override[:targets].to_a.any?
      mapped = override[:targets].map do |t|
        found = state.find do |r|
          r[:name].to_s == t ||
            r[:display_name].to_s == t ||
            r[:display_name].to_s.gsub(/\s+/, '') == t.gsub(/\s+/, '')
        end
        found ? found[:name].to_s : t
      end
      creature[:skill_target] = mapped.join(',')
    end
  end

  boss_preview = ''
  skill_name = BattleBossPatterns.pattern_name(creature)
  if !skill_name.empty? && skill_name != '-'
    whole = skill_name == '전체공격' ||
            BattleBossPatterns.range_shape(creature) == '전체' ||
            creature[:skill_range_default].to_s.strip == '전체'
    cells  = BattleBossPatterns.pattern_cells(creature)
    target = BattleBossPatterns.skill_target(creature)

    if !whole && cells.empty? && target.empty?
      alive = state.select { |r| r[:hp].to_i > 0 }
      picked = alive.sample([BattleBossPatterns.target_count(creature), 1].max)
      creature[:skill_target] = picked.map { |r| r[:name].to_s }.join(',')
      target = creature[:skill_target]
    end

    display_of = lambda do |id|
      found = state.find { |r| r[:name].to_s == id.to_s }
      found ? found[:display_name].to_s : id.to_s
    end

    label = if whole
              '전체'
            elsif cells.any?
              cells.join(', ')
            elsif !target.empty?
              target.split(',').map(&:strip).map { |t| display_of.call(t) }.join(', ')
            else
              ''
            end

    unless label.empty?
      power = BattleBossPatterns.pattern_damage(creature, BattleBossPatterns.pattern_multiplier(creature))
      boss_preview  = "공격 대상(범위): #{label}\n"
      boss_preview += "위력: #{power}\n" if power.to_i > 0 && BattleBossPatterns.skill_category(creature) != '디버프'
      boss_preview += "\n"
    end
  end

  omen = creature[:omen].to_s.strip
  omen_block = omen.empty? ? '' : "#{omen}\n\n"

  alive_for_map = state.select { |r| r[:hp].to_i > 0 }
  map_lines = BattleGrid.render(alive_for_map, creature)

  creature_name = creature[:name].to_s.strip
  creature_name = '보스이름' if creature_name.empty? || creature_name == '크리쳐'
  attack_lines = ["[스킬명/#{creature_name}]"]

  announcement = "#{session.runner_tags}\n\n" \
                 "[#{session.round}라운드] #{creature[:name]}와의 전투!\n\n" \
                 "#{omen_block}" \
                 "#{boss_preview}" \
                 "#{creature[:name]} 상태: #{view_sheet.health_bar(creature[:hp], creature[:max_hp])} (위치: #{creature[:pos]}, 크기: #{creature[:size] || '1x1'})\n\n" \
                 "전장\n\n" \
                 "#{map_lines.join("\n")}\n" \
                 "───────────────────\n" \
                 "DM 또는 멘션으로 행동을 입력해주세요.\n\n" \
                 "형식:\n" \
                 "공격: #{attack_lines.join("\n")}\n" \
                 "지원: [스킬명/아이디]\n" \
                 "방어: [스킬명/아이디]\n" \
                 "이동: [이동/좌표]\n" \
                 "입력 대기: 5분\n" \
                 "───────────────────"

  response, new_time = post_session_thread(session, announcement, last_post_time)
  if response && response['id']
    session.announced = true
    session.phase = :battle
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 안내 송출"
  else
    session.announced = false
    session.phase = :announcing
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 안내 송출 실패"
  end
  new_time
end

def find_session_for_action(sessions, username, status = nil)
  username = username.to_s.gsub('@', '').strip
  active = sessions.values.select { |s| s.active && s.includes_runner?(username) }
  return nil if active.empty?

  if status
    related = active.find { |s| s.related_to_status?(status) }
    return related if related
  end

  active.max_by { |s| s.start_time }
end

def process_action_for_session(session, username, text, processed_set, processed_id, runner_sheet, view_sheet, listener, processed_action_status_ids = nil, status_id = nil)
  status_id ||= processed_id
  if processed_action_status_ids && processed_action_status_ids.include?(status_id.to_s)
    processed_set.add(processed_id)
    return false
  end

  before = session.actions.size

  record_battle_action(
    username,
    text,
    session.actions,
    session.processed_messages,
    processed_set,
    processed_id,
    session.runner_names,
    view_sheet,
    runner_sheet,
    session.creature,
    listener,
    session.passive_ctx
  )

  changed = session.actions.size > before
  processed_action_status_ids.add(status_id.to_s) if processed_action_status_ids && changed
  changed
end

def settle_session_if_needed(session, runner_sheet, creature_sheet, view_sheet, last_post_time)
  return [last_post_time, false] unless session.active
  return [last_post_time, false] unless session.phase == :battle

  required = session.required_actions
  round_done = required > 0 && session.actions.size >= required
  round_timeout = (Time.now - session.start_time) >= ACTION_WAIT_SECONDS
  return [last_post_time, false] unless round_done || round_timeout

  session.passive_ctx[:round] = session.round.to_i
  begin
    log, runner_state = settle_round(
      session.actions,
      session.runner_names,
      runner_sheet,
      creature_sheet,
      view_sheet,
      session.creature,
      session.passive_ctx
    )
  rescue => e
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 정산 실패: #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    sheet_log(creature_sheet, session.id, session.round, '정산 실패',
              "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}\n보스행동커맨드 입력 시 다음 라운드로 진행됩니다.")
    session.round += 1
    session.phase = :boss_command
    session.awaiting_boss = true
    session.announced = false
    session.actions = {}
    session.processed_messages = {}
    session.start_time = Time.now
    session.auto_next_round_timer = nil
    begin
      response, new_time = post_session_thread(session, "#{session.runner_tags}\n\n[안내] 라운드 정산 중 오류가 발생했습니다. 운영 계정이 보스 행동을 입력하면 다음 라운드로 진행됩니다.", last_post_time)
      last_post_time = new_time
    rescue => post_err
      puts "[전투봇] 정산 실패 안내 송출 실패: #{post_err.class}: #{post_err.message}"
    end
    return [last_post_time, false]
  end

  result = build_result_text(
    session.runner_tags,
    session.round,
    session.creature,
    session.actions,
    session.runner_names,
    log,
    runner_state,
    view_sheet,
    timeout: round_timeout && !round_done
  )

  Array(result).each do |part|
    response, new_time = post_session_thread(session, part, last_post_time)
    last_post_time = new_time
  end

  dead = runner_state.select { |r| session.runner_names.include?(r[:name].to_s) && r[:hp].to_i <= 0 }.map { |r| r[:name].to_s }
  session.mark_dead_runners(dead)

  creature_dead = session.creature[:hp].to_i <= 0
  all_runners_dead = runner_state.none? { |r| session.runner_names.include?(r[:name]) && r[:hp].to_i > 0 }

  ctx = session.passive_ctx
  positions = (ctx[:positions] ||= {})

  actions_text = session.actions.map { |name, act| "#{name}: [#{act[:type]}/#{act[:target]}]" }.join(' / ')
  sheet_log(creature_sheet, session.id, session.round, '정산',
            "행동: #{actions_text.empty? ? '없음' : actions_text}\n\n#{Array(log).join("\n")}")

  if creature_dead || all_runners_dead
    session.active = false
    session.auto_next_round_timer = nil
    session.awaiting_boss = false
    puts "[전투봇] [세션 #{session.id}] 전투 종결 (#{creature_dead ? '승리' : '패배'})"
    sheet_log(creature_sheet, session.id, session.round, '전투 종결', creature_dead ? '크리쳐 격파 - 승리' : '전원 전투불가 - 패배')
    [last_post_time, true]
  else
    session.round += 1
    session.phase = :boss_command
    session.awaiting_boss = true
    session.announced = false
    session.actions = {}
    session.processed_messages = {}
    session.start_time = Time.now
    session.auto_next_round_timer = nil
    
    if session.auto_mode
      auto_skill = select_auto_skill(session.creature, creature_sheet)
      if auto_skill
        session.passive_ctx[:boss_override] = { skill: auto_skill }
        session.awaiting_boss = false
        session.phase = :announcing
      end
    end
    
    puts "[전투봇] [세션 #{session.id}] #{session.round - 1}라운드 정산 완료 - #{session.round}라운드 보스행동커맨드 대기"
    [last_post_time, false]
  end
end

def select_auto_skill(creature, creature_sheet)
  return nil unless creature && creature_sheet
  begin
    rows = creature_sheet.read("'보스스킬'!A2:A")
    names = rows.map { |r| r[0].to_s.strip }.reject(&:empty?)
    return nil if names.empty?
    names.sample
  rescue => e
    puts "[select_auto_skill 오류] #{e.class}: #{e.message}"
    nil
  end
end

fetch_public_statuses.each { |s| processed_statuses.add(s['id']) if s['id'] }
snapshot_current_dm_ids(processed_dm_ids)
snapshot_current_notification_ids(processed_notification_ids)
puts '[전투봇] 기존 툿/DM/멘션 스냅샷 완료 (재발동 방지)'

bot_on = false
last_trigger_check = Time.at(0)

loop do
  begin
    if (Time.now - last_trigger_check) >= TRIGGER_CHECK_INTERVAL
      new_bot_on = $trigger_sheet.read_bot_on_or_nil
      new_bot_on = bot_on if new_bot_on.nil?
      last_trigger_check = Time.now

      if new_bot_on && !bot_on
        fetch_public_statuses.each { |s| processed_statuses.add(s['id']) if s['id'] }
        snapshot_current_dm_ids(processed_dm_ids)
        snapshot_current_notification_ids(processed_notification_ids)
        puts '[전투봇] 전투봇 켜짐 (실행 탭 A2 체크)'
      elsif !new_bot_on && bot_on
        puts '[전투봇] 전투봇 꺼짐 (실행 탭 A2 해제)'
      end

      bot_on = new_bot_on
    end

    unless bot_on
      sleep(3)
      next
    end

    sessions.values.each { |session| check_prep_completion(session, creature_sheet) }

    sessions.values.each do |session|
      next unless session.auto_next_round_timer
      next unless (Time.now - session.auto_next_round_timer) >= ROUND_WAIT_SECONDS

      session.reset_for_next_round!
      snapshot_current_dm_ids(processed_dm_ids)
      snapshot_current_notification_ids(processed_notification_ids)
      puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 자동 시작"
    end

    conversations = fetch_conversations

    conversations.each do |conv|
      last_status = conv['last_status']
      next unless last_status

      sender = last_status['account'] || conv['accounts'].to_a.first
      next unless sender

      dm_id = last_status['id']
      next if processed_dm_ids.include?(dm_id)

      username = sender['username'].to_s.gsub('@', '').strip
      content = clean_html(last_status['content'])

      if battle_start_text?(content)
        if sessions.key?(last_status['id'])
          processed_dm_ids.add(dm_id)
          next
        end
        session = create_battle_session_from_status(last_status, content, :dm, creature_sheet, BOT_USERNAME, username)
        if session
          sessions[session.id] = session
          auto_enabled = $trigger_sheet.read_auto_mode
          session.auto_mode = auto_enabled if auto_enabled
          puts "[전투봇] [세션 #{session.id}] DM 전투 시작 - 참여자 #{session.runner_names.join(', ')}, 상대: #{session.creature[:name]} @#{session.creature[:pos]}"
          sheet_log(creature_sheet, session.id, session.round, '전투 시작', "DM / 참여자: #{session.runner_names.join(', ')} / 상대: #{session.creature[:name]} @#{session.creature[:pos]}")
        end
        processed_dm_ids.add(dm_id)
        next
      end

      if battle_end_text?(content)
        target = find_session_for_action(sessions, username, last_status)
        target ||= sessions.values.select(&:active).max_by(&:start_time)
        if target
          target.active = false
          target.auto_next_round_timer = nil
          response, new_time = post_session_thread(target, "#{target.runner_tags}\n\n[전투 중단]", last_post_time)
          last_post_time = new_time
          puts "[전투봇] [세션 #{target.id}] DM 전투 중단"
          sheet_log(creature_sheet, target.id, target.round, '전투 중단', "@#{username} 의 종료 명령")
        end
        processed_dm_ids.add(dm_id)
        next
      end

      boss_sid = last_status['id'].to_s
      if handled_boss_status_ids.include?(boss_sid)
        processed_dm_ids.add(dm_id)
        next
      end
      handled_boss_status_ids.add(boss_sid)
      case try_boss_command!(sessions, username, last_status, content, creature_sheet, quiet_hold: held_boss_logged_ids.include?(boss_sid))
      when :applied, :ignored
        processed_dm_ids.add(dm_id)
        next
      when :hold
        handled_boss_status_ids.delete(boss_sid)
        held_boss_logged_ids.add(boss_sid)
        next
      end
      handled_boss_status_ids.delete(boss_sid)

      if bot_status?(last_status, BOT_USERNAME)
        processed_dm_ids.add(dm_id)
        next
      end

      session = find_session_for_action(sessions, username, last_status)
      unless session
        processed_dm_ids.add(dm_id)
        next
      end

      if session.phase == :prep
        handle_prep_input(session, username, content, processed_dm_ids, dm_id, listener, processed_action_status_ids, last_status['id'])
        next
      end

      unless session.phase == :battle
        processed_dm_ids.add(dm_id)
        next
      end

      process_action_for_session(session, username, content, processed_dm_ids, dm_id, runner_sheet, view_sheet, listener, processed_action_status_ids, dm_id)
    end

    fetch_public_statuses.each do |status|
      status_id = status['id']
      next if processed_statuses.include?(status_id)

      content = clean_html(status['content'])

      if battle_start_text?(content)
        if sessions.key?(status_id)
          processed_statuses.add(status_id)
          next
        end
        session = create_battle_session_from_status(status, content, :public, creature_sheet, BOT_USERNAME, nil)
        if session
          sessions[session.id] = session
          auto_enabled = $trigger_sheet.read_auto_mode
          session.auto_mode = auto_enabled if auto_enabled
          puts "[전투봇] [세션 #{session.id}] 공개 전투 시작 - 참여자 #{session.runner_names.join(', ')}, 상대: #{session.creature[:name]} @#{session.creature[:pos]}"
          sheet_log(creature_sheet, session.id, session.round, '전투 시작', "공개 / 참여자: #{session.runner_names.join(', ')} / 상대: #{session.creature[:name]} @#{session.creature[:pos]}")
        else
          listener.post_public('[전투 오류] 참여자가 없습니다. 태그를 추가하세요.')
          puts '[전투봇] 태그된 러너 없음'
        end
        processed_statuses.add(status_id)
        next
      end

      pub_sender = status.dig('account', 'username').to_s
      boss_sid = status_id.to_s
      if handled_boss_status_ids.include?(boss_sid)
        processed_statuses.add(status_id)
        next
      end
      handled_boss_status_ids.add(boss_sid)
      case try_boss_command!(sessions, pub_sender, status, content, creature_sheet, quiet_hold: held_boss_logged_ids.include?(boss_sid))
      when :applied, :ignored
        processed_statuses.add(status_id)
        next
      when :hold
        handled_boss_status_ids.delete(boss_sid)
        held_boss_logged_ids.add(boss_sid)
        next
      end
      handled_boss_status_ids.delete(boss_sid)

      if battle_end_text?(content)
        end_sid = status_id.to_s

        if handled_battle_end_status_ids.include?(end_sid)
          processed_statuses.add(status_id)
          next
        end

        active_sessions = sessions.values.select(&:active)
        target = active_sessions.find { |s| s.related_to_status?(status) }

        target ||= active_sessions.first if active_sessions.length == 1

        if target
          target.active = false
          target.auto_next_round_timer = nil
          target.awaiting_boss = false
          handled_battle_end_status_ids.add(end_sid)

          response, new_time = post_session_thread(target, '[전투 중단]', last_post_time)
          last_post_time = new_time
          puts "[전투봇] [세션 #{target.id}] 공개 전투 중단"
          sheet_log(
            creature_sheet,
            target.id,
            target.round,
            '전투 중단',
            "공개 툿 종료 명령 / status=#{end_sid}"
          )
        else
          puts "[전투봇] 공개 종료 명령 무시: 연결 세션 불명확 status=#{end_sid}"
          sheet_log(
            creature_sheet,
            '-',
            '-',
            '전투 종료 명령 무시',
            "공개 종료 명령의 연결 세션 불명확 / status=#{end_sid}"
          )
        end
      end

      processed_statuses.add(status_id)
    end

    sessions.values.select(&:active).each do |session|
      if session.phase == :prep && !session.announced
        last_post_time = announce_prep_round(session, view_sheet, runner_sheet, last_post_time)
      elsif session.phase == :announcing
        last_post_time = announce_round(session, view_sheet, creature_sheet, runner_sheet, last_post_time)
      elsif session.phase == :boss_command && !session.announced
        last_post_time = announce_boss_turn(session, view_sheet, runner_sheet, last_post_time)
      end
    end

    fetch_notifications.each do |notification|
      notification_id = notification['id']
      next if processed_notification_ids.include?(notification_id)

      status = notification['status']
      unless status
        processed_notification_ids.add(notification_id)
        next
      end

      if bot_status?(status, BOT_USERNAME)
        processed_notification_ids.add(notification_id)
        next
      end

      username = notification.dig('account', 'username').to_s.gsub('@', '').strip
      text = clean_html(status['content'])

      boss_sid = status['id'].to_s
      if handled_boss_status_ids.include?(boss_sid)
        processed_notification_ids.add(notification_id)
        next
      end
      handled_boss_status_ids.add(boss_sid)
      case try_boss_command!(sessions, username, status, text, creature_sheet, quiet_hold: held_boss_logged_ids.include?(boss_sid))
      when :applied, :ignored
        processed_notification_ids.add(notification_id)
        next
      when :hold
        handled_boss_status_ids.delete(boss_sid)
        held_boss_logged_ids.add(boss_sid)
        next
      end
      handled_boss_status_ids.delete(boss_sid)

      if battle_start_text?(text)
        if sessions.key?(status['id'])
          processed_notification_ids.add(notification_id)
          next
        end
        session = create_battle_session_from_status(status, text, :mention, creature_sheet, BOT_USERNAME, username)
        if session
          sessions[session.id] = session
          processed_statuses.add(status['id'])
          auto_enabled = $trigger_sheet.read_auto_mode
          session.auto_mode = auto_enabled if auto_enabled
          puts "[전투봇] [세션 #{session.id}] 멘션 전투 시작 - 참여자 #{session.runner_names.join(', ')}, 상대: #{session.creature[:name]} @#{session.creature[:pos]}"
          sheet_log(creature_sheet, session.id, session.round, '전투 시작', "멘션 / 참여자: #{session.runner_names.join(', ')} / 상대: #{session.creature[:name]} @#{session.creature[:pos]}")
        else
          puts "[전투봇] 멘션 전투시작 실패: 참여자 없음 또는 파싱 실패 (@#{username})"
        end
        processed_notification_ids.add(notification_id)
        next
      end

      if battle_end_text?(text)
        end_sid = status['id'].to_s

        if handled_battle_end_status_ids.include?(end_sid)
          processed_notification_ids.add(notification_id)
          processed_statuses.add(status['id']) if status['id']
          next
        end

        active_sessions = sessions.values.select(&:active)

        target = active_sessions.find { |s| s.related_to_status?(status) }

        if target.nil?
          runner_sessions = active_sessions.select do |session|
            session.includes_runner?(username)
          end

          target = runner_sessions.first if runner_sessions.length == 1
        end

        target ||= active_sessions.first if active_sessions.length == 1

        if target
          target.active = false
          target.auto_next_round_timer = nil
          target.awaiting_boss = false
          handled_battle_end_status_ids.add(end_sid)

          response, new_time = post_session_thread(target, "#{target.runner_tags}\n\n[전투 중단]", last_post_time)
          last_post_time = new_time

          puts "[전투봇] [세션 #{target.id}] 멘션 전투 중단 / status=#{end_sid}"
          sheet_log(
            creature_sheet,
            target.id,
            target.round,
            '전투 중단',
            "@#{username} 의 종료 명령 / status=#{end_sid}"
          )
        else
          puts "[전투봇] 멘션 종료 명령 무시: 연결 세션 불명확 @#{username} status=#{end_sid}"
          sheet_log(
            creature_sheet,
            '-',
            '-',
            '전투 종료 명령 무시',
            "@#{username} / 연결 세션 불명확 / status=#{end_sid}"
          )
        end

        processed_statuses.add(status['id']) if status['id']
        processed_notification_ids.add(notification_id)
        next
      end

      session = find_session_for_action(sessions, username, status)
      unless session
        puts "[전투봇] 멘션 무시: 참여 중인 활성 세션 없음 @#{username}"
        processed_notification_ids.add(notification_id)
        next
      end

      if session.phase == :prep
        handle_prep_input(session, username, text, processed_notification_ids, notification_id, listener, processed_action_status_ids, status['id'])
        next
      end

      unless session.phase == :battle
        processed_notification_ids.add(notification_id)
        next
      end

      process_action_for_session(session, username, text, processed_notification_ids, notification_id, runner_sheet, view_sheet, listener, processed_action_status_ids, status['id'])
    end

    sessions.values.each do |session|
      last_post_time, _ = settle_session_if_needed(session, runner_sheet, creature_sheet, view_sheet, last_post_time)
    end

    sessions.delete_if { |_id, session| session.finished? }

  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    sheet_log(creature_sheet, '-', '-', '오류',
              "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}")
  end

  sleep(3)
end

