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

RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
BOT_USERNAME      = ENV['BOT_USERNAME'] || 'DOWN'

LOCATION_MAP = {
  '스토디시' => 'E7',
  'A' => 'A1', 'B' => 'B1', 'C' => 'C1', 'D' => 'D1',
  'E' => 'E1', 'F' => 'F1', 'G' => 'G1'
}

ROUND_WAIT_SECONDS = 60
ACTION_WAIT_SECONDS = 300

puts "[전투봇] 시작"

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

puts "[전투봇] 초기화 완료 - 공개 타임라인 모니터링"

processed_statuses = Set.new
processed_dm_ids = Set.new

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

def clean_html(text)
  text.to_s.gsub(/<[^>]*>/, '').strip
end

def fetch_public_statuses
  uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/timelines/public?local=true")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"

  res = http.request(req)
  return [] unless res.code == '200'

  JSON.parse(res.body)
rescue => e
  puts "[전투봇 오류] 공개 타임라인 조회 실패: #{e.class}: #{e.message}"
  []
end

def fetch_conversations
  uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/conversations")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"

  res = http.request(req)
  return [] unless res.code == '200'

  JSON.parse(res.body)
rescue => e
  puts "[전투봇 오류] DM 조회 실패: #{e.class}: #{e.message}"
  []
end

def snapshot_current_dm_ids(processed_dm_ids)
  fetch_conversations.each do |conv|
    last_status = conv['last_status']
    next unless last_status && last_status['id']

    processed_dm_ids.add(last_status['id'])
  end
end

def current_creature(creature_sheet)
  config = creature_sheet.read_creature_config || { name: '크리쳐' }
  creature_sheet.read_creature_stats(config[:name]) || {
    name: config[:name] || '크리쳐',
    hp: 200,
    max_hp: 200,
    pos: 'D4'
  }
end

def extract_usernames_from_status(status, content, bot_username)
  usernames = status['mentions'].to_a.map { |m| m['username'].to_s.strip }.reject(&:empty?).uniq

  if usernames.empty?
    usernames = content.scan(/@([A-Za-z0-9_]+)/).flatten.uniq
  end

  usernames.reject { |u| u == bot_username }.uniq
end

def build_result_text(runner_tags, battle_round, creature, battle_actions, elapsed, timeout: false)
  creature_name = creature[:name] || creature[:이름] || '크리쳐'
  creature_hp = creature[:hp] || 200
  creature_max_hp = creature[:max_hp] || creature_hp

  title = timeout ? "[#{battle_round}라운드] #{creature_name} 전투 결과 (시간 초과)" : "[#{battle_round}라운드] #{creature_name} 전투 결과"

  result = "#{runner_tags}\n\n#{title}\n\n"
  result += "───────────────────\n"

  if battle_actions.empty?
    result += "입력된 행동 없음\n"
  else
    battle_actions.each do |username, action|
      result += "#{username}: [#{action[:type]}/#{action[:target]}]\n"
    end
  end

  result += "───────────────────\n"
  result += "#{creature_name} 상태: 건강 #{creature_hp}/#{creature_max_hp}\n\n"
  result += timeout ? "전투 정산 완료! (5분)" : "전투 정산 완료! (#{elapsed}초)"

  result
end

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
      auto_next_round_timer = nil

      puts "[전투봇] #{battle_round}라운드 자동 시작"
    end

    statuses = fetch_public_statuses

    statuses.each do |status|
      status_id = status['id']
      next if processed_statuses.include?(status_id)

      account_username = status.dig('account', 'username')

      if account_username == BOT_USERNAME
        processed_statuses.add(status_id)
        next
      end

      content = clean_html(status['content'])

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

        battle_active = true
        battle_announced = false
        battle_start_time = Time.now
        battle_round = content.match(/\[(\d+)\]/)&.[](1) || "1"
        battle_actions = {}
        processed_messages = {}
        snapshot_current_dm_ids(processed_dm_ids)
        auto_next_round_timer = nil

        creature = current_creature(creature_sheet)
        creature_name = creature[:name] || "크리쳐"

        puts "[전투봇] #{battle_round}라운드 시작 - 참여자 #{total_runners}명 (#{runner_names.join(', ')}), 상대: #{creature_name}"

        processed_statuses.add(status_id)

      elsif content.include?('[전투종료]')
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        auto_next_round_timer = nil

        listener.post_public("[전투 강제 종료]")
        puts "[전투봇] 전투 종료"

        processed_statuses.add(status_id)
      else
        processed_statuses.add(status_id)
      end
    end

    if battle_active
      unless battle_announced
        creature = current_creature(creature_sheet)
        creature_name = creature[:name] || "크리쳐"

        announcement = "#{runner_tags}\n\n[#{battle_round}라운드] #{creature_name}와의 전투!\n\n" \
                       "───────────────────\n" \
                       "DM으로 행동을 입력해주세요.\n\n" \
                       "형식:\n" \
                       "  [공격/크리쳐]\n" \
                       "  [회복/아이디]\n" \
                       "  [방어/아이디]\n" \
                       "  [이동/좌표]\n\n" \
                       "입력 대기: 5분\n" \
                       "───────────────────"

        listener.post_public(announcement)
        battle_announced = true

        puts "[전투봇] #{battle_round}라운드 안내 송출"
      end

      conversations = fetch_conversations

      conversations.each do |conv|
        sender = conv['accounts'].first
        next unless sender

        username = sender['username']
        next unless runner_names.include?(username)
        next if processed_messages[username]

        last_status = conv['last_status']
        next unless last_status

        dm_id = last_status['id']
        next if processed_dm_ids.include?(dm_id)

        text = clean_html(last_status['content'])
        match = text.match(/\[(공격|회복|방어|이동)\/(.+?)\]/)
        next unless match

        action_type = match[1]
        action_target = match[2].strip

        if action_type == '이동'
          coord = LOCATION_MAP[action_target] || action_target
          coord = coord.to_s.strip.upcase

          runner_state = view_sheet.read_runner_state
          runner = runner_state.find { |r| r[:name] == username }

          if runner
            runner[:pos] = coord
            view_sheet.update_runner_state(runner_state)
            puts "[전투봇] #{username} 이동 → #{coord}"
          else
            puts "[전투봇] #{username} 이동 실패 - 현황 시트에서 러너를 찾을 수 없음"
          end
        end

        battle_actions[username] = {
          type: action_type,
          target: action_target
        }

        processed_messages[username] = true
        processed_dm_ids.add(dm_id)

        puts "[전투봇] #{username} → [#{action_type}/#{action_target}]"

        listener.send_dm(username, "확인, 대기해주세요.")

        if battle_actions.size >= total_runners
          creature = current_creature(creature_sheet)

          result = build_result_text(
            runner_tags,
            battle_round,
            creature,
            battle_actions,
            (Time.now - battle_start_time).to_i,
            timeout: false
          )

          listener.post_public(result)

          battle_active = false
          auto_next_round_timer = Time.now

          puts "[전투봇] 모든 러너 입력 완료 - #{ROUND_WAIT_SECONDS}초 후 다음라운드"
        end
      end

      if battle_active && (Time.now - battle_start_time) >= ACTION_WAIT_SECONDS
        creature = current_creature(creature_sheet)

        result = build_result_text(
          runner_tags,
          battle_round,
          creature,
          battle_actions,
          ACTION_WAIT_SECONDS,
          timeout: true
        )

        listener.post_public(result)

        battle_active = false
        auto_next_round_timer = Time.now

        puts "[전투봇] #{battle_round}라운드 5분 경과 - #{ROUND_WAIT_SECONDS}초 후 다음라운드"
      end
    end

  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
  end

  sleep(10)
end
