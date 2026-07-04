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
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
BOT_USERNAME      = ENV['BOT_USERNAME'] || 'DOWN'

ROUND_WAIT_SECONDS = 60
ACTION_WAIT_SECONDS = 300

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

puts '[전투봇] 초기화 완료 - 다중 전투 세션 모드'

processed_statuses = Set.new
processed_dm_ids = Set.new
processed_notification_ids = Set.new
processed_action_status_ids = Set.new
sessions = {}

# ──────────────────────────────────────────────
# 세션 유틸
# ──────────────────────────────────────────────

def create_battle_session_from_status(status, content, mode, creature_sheet, bot_username, fallback_sender = nil)
  usernames = extract_usernames_from_status(status, content, bot_username)
  usernames = usernames.map { |u| u.to_s.gsub('@', '').strip }.reject(&:empty?).uniq

  if usernames.empty? && fallback_sender
    usernames = [fallback_sender.to_s.gsub('@', '').strip]
  end

  return nil if usernames.empty?

  creature = creature_from_start_content(content, creature_sheet)
  creature[:pos] = 'D4' if creature[:pos].to_s.strip.empty?

  BattleSession.new(
    id: status['id'],
    mode: mode,
    runner_names: usernames,
    creature: creature,
    thread_reply_id: status['id'],
    round: content.match(/\[(\d+)\]/)&.[](1) || 1
  )
end

def post_session_thread(session, text)
  response = post_battle_thread(text, session.dm_mode?, session.thread_reply_id)
  session.mark_thread_id(response['id']) if response && response['id']
  response
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

def announce_round(session, view_sheet)
  attack_lines = ['[공격/크리쳐]']
  creature_name = session.creature[:name].to_s.strip
  attack_lines << "[공격/#{creature_name}]" unless creature_name.empty? || creature_name == '크리쳐'

  announcement = "#{session.runner_tags}\n\n[#{session.round}라운드] #{session.creature[:name]}와의 전투!\n" \
                 "#{session.creature[:name]} 상태: #{view_sheet.health_bar(session.creature[:hp], session.creature[:max_hp])} (위치: #{session.creature[:pos]}, 크기: #{session.creature[:size] || '1x1'})\n\n" \
                 "───────────────────\n" \
                 "DM 또는 멘션으로 행동을 입력해주세요.\n\n" \
                 "형식:\n" \
                 "#{attack_lines.join("\n")}\n" \
                 "[회복/아이디]\n" \
                 "[방어/아이디]\n" \
                 "[이동/좌표]\n\n" \
                 "입력 대기: 5분\n" \
                 "───────────────────"

  post_session_thread(session, announcement)
  session.announced = true
  puts "[전투봇] 세션 #{session.id} #{session.round}라운드 안내 송출#{session.dm_mode? ? ' (DM)' : ''}"
end

def find_session_for_action(sessions, username, status = nil)
  username = username.to_s.gsub('@', '').strip
  active = sessions.values.select { |s| s.active && s.includes_runner?(username) }
  return nil if active.empty?

  if status
    related = active.find { |s| s.related_to_status?(status) }
    return related if related
  end

  # 같은 사용자가 여러 전투에 동시에 들어간 경우에는 최신 세션을 우선합니다.
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
    listener
  )

  changed = session.actions.size > before
  processed_action_status_ids.add(status_id.to_s) if processed_action_status_ids && changed
  changed
end

def settle_session_if_needed(session, runner_sheet, creature_sheet, view_sheet)
  return unless session.active

  round_done = session.actions.size >= session.total_runners && session.total_runners > 0
  round_timeout = (Time.now - session.start_time) >= ACTION_WAIT_SECONDS
  return unless round_done || round_timeout

  session.passive_ctx[:round] = session.round.to_i
  log, runner_state = settle_round(
    session.actions,
    session.runner_names,
    runner_sheet,
    creature_sheet,
    view_sheet,
    session.creature,
    session.passive_ctx
  )

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

  post_session_thread(session, result)
  session.active = false

  creature_dead = session.creature[:hp].to_i <= 0
  all_runners_dead = runner_state.none? { |r| session.runner_names.include?(r[:name]) && r[:hp].to_i > 0 }

  if creature_dead || all_runners_dead
    session.auto_next_round_timer = nil
    puts "[전투봇] 세션 #{session.id} 전투 종결 (#{creature_dead ? '승리' : '패배'})"
  else
    session.auto_next_round_timer = Time.now
    puts "[전투봇] 세션 #{session.id} #{session.round}라운드 정산 완료 - #{ROUND_WAIT_SECONDS}초 후 다음 라운드"
  end
end

fetch_public_statuses.each { |s| processed_statuses.add(s['id']) if s['id'] }
snapshot_current_dm_ids(processed_dm_ids)
snapshot_current_notification_ids(processed_notification_ids)
puts '[전투봇] 기존 툿/DM/멘션 스냅샷 완료 (재발동 방지)'

loop do
  begin
    # 다음 라운드 자동 개시
    sessions.values.each do |session|
      next unless session.auto_next_round_timer
      next unless (Time.now - session.auto_next_round_timer) >= ROUND_WAIT_SECONDS

      session.reset_for_next_round!
      snapshot_current_dm_ids(processed_dm_ids)
      snapshot_current_notification_ids(processed_notification_ids)
      puts "[전투봇] 세션 #{session.id} #{session.round}라운드 자동 시작"
    end

    conversations = fetch_conversations

    # DM에서 전투 시작/종료/행동 처리
    conversations.each do |conv|
      sender = conv['accounts'].first
      last_status = conv['last_status']
      next unless sender && last_status

      dm_id = last_status['id']
      next if processed_dm_ids.include?(dm_id)

      username = sender['username'].to_s.gsub('@', '').strip
      content = clean_html(last_status['content'])

      if battle_start_text?(content)
        session = create_battle_session_from_status(last_status, content, :dm, creature_sheet, BOT_USERNAME, username)
        if session
          sessions[session.id] = session
          puts "[전투봇] DM 세션 시작 #{session.id} - 참여자 #{session.runner_names.join(', ')}, 상대: #{session.creature[:name]} @#{session.creature[:pos]}"
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
          post_session_thread(target, "#{target.runner_tags}\n\n[전투 중단]")
          puts "[전투봇] DM 세션 종료 #{target.id}"
        end
        processed_dm_ids.add(dm_id)
        next
      end

      if bot_status?(last_status, BOT_USERNAME)
        processed_dm_ids.add(dm_id)
        next
      end

      session = find_session_for_action(sessions, username, last_status)
      unless session
        processed_dm_ids.add(dm_id)
        next
      end

      process_action_for_session(session, username, content, processed_dm_ids, dm_id, runner_sheet, view_sheet, listener, processed_action_status_ids, dm_id)
    end

    # 공개 타임라인에서 전투 시작/종료 처리
    fetch_public_statuses.each do |status|
      status_id = status['id']
      next if processed_statuses.include?(status_id)

      content = clean_html(status['content'])

      if battle_start_text?(content)
        session = create_battle_session_from_status(status, content, :public, creature_sheet, BOT_USERNAME, nil)
        if session
          sessions[session.id] = session
          puts "[전투봇] 공개 세션 시작 #{session.id} - 참여자 #{session.runner_names.join(', ')}, 상대: #{session.creature[:name]} @#{session.creature[:pos]}"
        else
          listener.post_public('[전투 오류] 참여자가 없습니다. 태그를 추가하세요.')
          puts '[전투봇] 태그된 러너 없음'
        end
        processed_statuses.add(status_id)
        next
      end

      if battle_end_text?(content)
        target = sessions.values.select(&:active).find { |s| s.related_to_status?(status) }
        target ||= sessions.values.select(&:active).max_by(&:start_time)
        if target
          target.active = false
          target.auto_next_round_timer = nil
          post_session_thread(target, '[전투 중단]')
          puts "[전투봇] 공개 세션 종료 #{target.id}"
        end
      end

      processed_statuses.add(status_id)
    end

    # 라운드 안내
    sessions.values.select(&:active).each do |session|
      announce_round(session, view_sheet) unless session.announced
    end

    # 멘션 행동 처리
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

      if battle_start_text?(text) || battle_end_text?(text)
        processed_notification_ids.add(notification_id)
        next
      end

      session = find_session_for_action(sessions, username, status)
      unless session
        puts "[전투봇] 멘션 무시: 참여 중인 활성 세션 없음 @#{username}"
        processed_notification_ids.add(notification_id)
        next
      end

      process_action_for_session(session, username, text, processed_notification_ids, notification_id, runner_sheet, view_sheet, listener, processed_action_status_ids, status['id'])
    end

    # 정산
    sessions.values.each do |session|
      settle_session_if_needed(session, runner_sheet, creature_sheet, view_sheet)
    end

    # 끝난 세션 정리
    sessions.delete_if { |_id, session| session.finished? }

  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
  end

  sleep(3)
end
