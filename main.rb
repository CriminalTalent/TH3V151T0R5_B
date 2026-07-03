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
require_relative 'battle_round'

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

puts "[전투봇] 시작"

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

puts "[전투봇] 초기화 완료 - 공개 타임라인 + DM + 멘션 모니터링"

processed_statuses = Set.new
processed_dm_ids = Set.new
processed_notification_ids = Set.new

battle_active = false
battle_actions = {}
battle_start_time = nil
battle_round = nil
processed_messages = {}
battle_announced = false
total_runners = 0
runner_names = []
runner_tags = ""
auto_next_round_timer = nil
battle_creature = nil
dm_mode = false
passive_ctx = nil
battle_thread_reply_id = nil


fetch_public_statuses.each { |s| processed_statuses.add(s['id']) if s['id'] }
snapshot_current_dm_ids(processed_dm_ids)
snapshot_current_notification_ids(processed_notification_ids)
puts "[전투봇] 기존 툿/DM/멘션 스냅샷 완료 (재발동 방지)"

loop do
  begin
    if auto_next_round_timer && (Time.now - auto_next_round_timer) >= ROUND_WAIT_SECONDS
      battle_round = battle_round.to_i + 1
      battle_active = true
      battle_announced = false
      battle_start_time = Time.now
      battle_actions = {}
      processed_messages = {}
      snapshot_current_dm_ids(processed_dm_ids)
      snapshot_current_notification_ids(processed_notification_ids)
      auto_next_round_timer = nil

      puts "[전투봇] #{battle_round}라운드 자동 시작"
    end

    conversations = fetch_conversations

    conversations.each do |conv|
      sender = conv['accounts'].first
      next unless sender

      last_status = conv['last_status']
      next unless last_status

      dm_id = last_status['id']
      next if processed_dm_ids.include?(dm_id)

      content = clean_html(last_status['content'])

      # 같은 계정/토큰을 조사봇과 전투봇이 함께 쓰는 테스트 환경에서는
      # 조사봇이 올린 [전투시작]도 전투봇 입장에서는 '자기 글'처럼 보입니다.
      # 따라서 전투 시작/종료 이벤트는 bot_status? 여부와 관계없이 처리합니다.
      if bot_status?(last_status, BOT_USERNAME) &&
         !content.include?('[전투시작]') &&
         !content.include?('[전투종료]')
        processed_dm_ids.add(dm_id)
        next
      end

      if content.include?('[전투시작]') && !battle_active
        usernames = extract_usernames_from_status(last_status, content, BOT_USERNAME)
        usernames = (usernames - [sender['username']]).uniq
        usernames = [sender['username']] if usernames.empty?
        total_runners = usernames.size

        runner_names = usernames
        runner_tags = runner_names.map { |u| "@#{u}" }.join(" ")

        dm_mode = true
        battle_active = true
        battle_announced = false
        battle_start_time = Time.now
        battle_round = content.match(/\[(\d+)\]/)&.[](1) || "1"
        battle_actions = {}
        processed_messages = {}
        auto_next_round_timer = nil
        passive_ctx = new_passive_ctx
        battle_thread_reply_id = status_id

        battle_creature = creature_from_start_content(content, creature_sheet)
        battle_creature[:pos] = 'D4' if battle_creature[:pos].to_s.strip.empty?
        # 현재 위치 시트에는 크리쳐/전투상태 탭이 없을 수 있으므로 메모리 상태만 사용합니다.
        puts "[전투봇] 크리쳐 확정: #{battle_creature[:name]} @#{battle_creature[:pos]} HP=#{battle_creature[:hp]}/#{battle_creature[:max_hp]}"

        processed_dm_ids.add(dm_id)
        snapshot_current_dm_ids(processed_dm_ids)
        snapshot_current_notification_ids(processed_notification_ids)

        puts "[전투봇] (DM 테스트) #{battle_round}라운드 시작 - 참여자 #{total_runners}명 (#{runner_names.join(', ')}), 상대: #{battle_creature[:name]} @#{battle_creature[:pos]}"

      elsif content.include?('[전투종료]') && battle_active
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        auto_next_round_timer = nil
        battle_creature = nil
        passive_ctx = nil

        response = post_battle_thread("#{runner_tags}\n\n[전투 강제 종료]", dm_mode, battle_thread_reply_id)
        battle_thread_reply_id = response['id'] if response && response['id']
        processed_dm_ids.add(dm_id)
        dm_mode = false
        puts "[전투봇] 전투 종료 (DM)"
      else
        processed_dm_ids.add(dm_id)
      end
    end

    fetch_public_statuses.each do |status|
      status_id = status['id']
      next if processed_statuses.include?(status_id)

      content = clean_html(status['content'])

      # 같은 계정/토큰 환경에서도 [전투시작]/[전투종료]는 반드시 처리합니다.
      if bot_status?(status, BOT_USERNAME) &&
         !content.include?('[전투시작]') &&
         !content.include?('[전투종료]')
        processed_statuses.add(status_id)
        next
      end

      if content.include?('[전투시작]') && !battle_active
        usernames = extract_usernames_from_status(status, content, BOT_USERNAME)
        total_runners = usernames.size

        if total_runners == 0
          listener.post_public("[전투 오류] 참여자가 없습니다. 태그를 추가하세요.")
          puts "[전투봇] 태그된 러너 없음"
          processed_statuses.add(status_id)
          next
        end

        runner_names = usernames
        runner_tags = runner_names.map { |u| "@#{u}" }.join(" ")

        dm_mode = false
        battle_active = true
        battle_announced = false
        battle_start_time = Time.now
        battle_round = content.match(/\[(\d+)\]/)&.[](1) || "1"
        battle_actions = {}
        processed_messages = {}
        snapshot_current_dm_ids(processed_dm_ids)
        snapshot_current_notification_ids(processed_notification_ids)
        auto_next_round_timer = nil
        passive_ctx = new_passive_ctx
        battle_thread_reply_id = status_id

        battle_creature = creature_from_start_content(content, creature_sheet)
        battle_creature[:pos] = 'D4' if battle_creature[:pos].to_s.strip.empty?
        # 현재 위치 시트에는 크리쳐/전투상태 탭이 없을 수 있으므로 메모리 상태만 사용합니다.
        puts "[전투봇] 크리쳐 확정: #{battle_creature[:name]} @#{battle_creature[:pos]} HP=#{battle_creature[:hp]}/#{battle_creature[:max_hp]}"

        puts "[전투봇] #{battle_round}라운드 시작 - 참여자 #{total_runners}명 (#{runner_names.join(', ')}), 상대: #{battle_creature[:name]} @#{battle_creature[:pos]}"

      elsif content.include?('[전투종료]')
        was_active = battle_active
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        auto_next_round_timer = nil
        battle_creature = nil
        passive_ctx = nil

        response = post_battle_thread(dm_mode && was_active ? "#{runner_tags}\n\n[전투 강제 종료]" : "[전투 강제 종료]", dm_mode, battle_thread_reply_id)
        battle_thread_reply_id = response['id'] if response && response['id']
        dm_mode = false
        puts "[전투봇] 전투 종료"
      end

      processed_statuses.add(status_id)
    end

    if battle_active
      battle_creature ||= current_creature(creature_sheet)
      passive_ctx ||= new_passive_ctx

      unless battle_announced
        announcement = "#{runner_tags}\n\n[#{battle_round}라운드] #{battle_creature[:name]}와의 전투!\n" \
                       "#{battle_creature[:name]} 상태: #{view_sheet.health_bar(battle_creature[:hp], battle_creature[:max_hp])} (위치: #{battle_creature[:pos]})\n\n" \
                       "───────────────────\n" \
                       "DM 또는 멘션으로 행동을 입력해주세요.\n\n" \
                       "형식:\n" \
                       "[공격/크리쳐]\n" \
                       "[회복/아이디]\n" \
                       "[방어/아이디]\n" \
                       "[이동/좌표]\n\n" \
                       "입력 대기: 5분\n" \
                       "───────────────────"

        response = post_battle_thread(announcement, dm_mode, battle_thread_reply_id)
        battle_thread_reply_id = response['id'] if response && response['id']
        battle_announced = true
        snapshot_current_dm_ids(processed_dm_ids)

        puts "[전투봇] #{battle_round}라운드 안내 송출#{dm_mode ? ' (DM)' : ''}"
      end

      fetch_notifications.each do |notification|
        notification_id = notification['id']
        next if processed_notification_ids.include?(notification_id)

        status = notification['status']
        unless status
          processed_notification_ids.add(notification_id)
          next
        end

        text = clean_html(status['content'])

        if bot_status?(status, BOT_USERNAME)
          puts "[전투봇] 멘션 무시: 봇 작성글 notification_id=#{notification_id}"
          processed_notification_ids.add(notification_id)
          next
        end

        username = notification.dig('account', 'username').to_s.strip
        unless runner_names.include?(username)
          puts "[전투봇] 멘션 무시: 참여자 아님 @#{username}, 참여자=#{runner_names.join(',')}"
          processed_notification_ids.add(notification_id)
          next
        end

        if text.include?('[전투시작]') || text.include?('[전투종료]')
          processed_notification_ids.add(notification_id)
          next
        end

        record_battle_action(
          username,
          text,
          battle_actions,
          processed_messages,
          processed_notification_ids,
          notification_id,
          runner_names,
          view_sheet,
          runner_sheet,
          battle_creature,
          listener
        )
      end

      conversations.each do |conv|
        sender = conv['accounts'].first
        next unless sender

        username = sender['username']
        last_status = conv['last_status']
        next unless last_status

        dm_id = last_status['id']
        next if processed_dm_ids.include?(dm_id)

        text = clean_html(last_status['content'])

        if bot_status?(last_status, BOT_USERNAME)
          puts "[전투봇] DM 무시: 봇 작성글 dm_id=#{dm_id}"
          processed_dm_ids.add(dm_id)
          next
        end

        unless runner_names.include?(username)
          puts "[전투봇] DM 무시: 참여자 아님 @#{username}, 참여자=#{runner_names.join(',')}"
          processed_dm_ids.add(dm_id)
          next
        end

        if text.include?('[전투시작]') || text.include?('[전투종료]')
          processed_dm_ids.add(dm_id)
          next
        end

        record_battle_action(
          username,
          text,
          battle_actions,
          processed_messages,
          processed_dm_ids,
          dm_id,
          runner_names,
          view_sheet,
          runner_sheet,
          battle_creature,
          listener
        )
      end

      round_done = battle_actions.size >= total_runners && total_runners > 0
      round_timeout = (Time.now - battle_start_time) >= ACTION_WAIT_SECONDS

      if round_done || round_timeout
        passive_ctx[:round] = battle_round.to_i
        log, runner_state = settle_round(battle_actions, runner_names, runner_sheet, creature_sheet, view_sheet, battle_creature, passive_ctx)
        # 현재 위치 시트에는 크리쳐/전투상태 탭이 없을 수 있으므로 메모리 상태만 사용합니다.

        result = build_result_text(
          runner_tags,
          battle_round,
          battle_creature,
          battle_actions,
          runner_names,
          log,
          runner_state,
          view_sheet,
          timeout: round_timeout && !round_done
        )

        response = post_battle_thread(result, dm_mode, battle_thread_reply_id)
        battle_thread_reply_id = response['id'] if response && response['id']

        battle_active = false

        creature_dead = battle_creature[:hp].to_i <= 0
        all_runners_dead = runner_state.none? { |r| runner_names.include?(r[:name]) && r[:hp].to_i > 0 }

        if creature_dead || all_runners_dead
          auto_next_round_timer = nil
          battle_creature = nil
          passive_ctx = nil
          battle_thread_reply_id = nil
          dm_mode = false
          puts "[전투봇] 전투 종결 (#{creature_dead ? '승리' : '패배'})"
        else
          auto_next_round_timer = Time.now
          puts "[전투봇] #{battle_round}라운드 정산 완료 - #{ROUND_WAIT_SECONDS}초 후 다음라운드"
        end
      end
    end

  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
  end

  sleep(3)
end
