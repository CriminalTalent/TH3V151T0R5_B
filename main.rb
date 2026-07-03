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

puts "[전투봇] 초기화 완료 - 공개 타임라인 + DM 모니터링"

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
battle_creature = nil
dm_mode = false

# dm_mode면 단체 DM, 아니면 퍼블릭 툿 (text에는 runner_tags 멘션이 포함되어야 함)
broadcast = ->(text) { dm_mode ? listener.post_direct(text) : listener.post_public(text) }

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
  usernames = content.scan(/@([A-Za-z0-9_]+)/).flatten.uniq if usernames.empty?
  usernames.reject { |u| u == bot_username }.uniq
end

def normalize_target(target)
  target.to_s.strip.sub(/^@/, '')
end

def runner_alive?(runner)
  runner && runner[:hp].to_i > 0
end

def validate_action(username, action_type, action_target, runner_names, view_sheet, creature)
  runner_state = view_sheet.read_runner_state
  actor = runner_state.find { |r| r[:name] == username }

  return [false, "현재 행동할 수 없는 상태입니다."] unless runner_alive?(actor)

  case action_type
  when '공격'
    target = normalize_target(action_target)
    creature_name = creature[:name].to_s

    unless ['크리쳐', creature_name].include?(target)
      return [false, "대상을 찾을 수 없습니다. 아이디 또는 크리쳐 이름을 확인해주세요."]
    end

  when '회복', '방어'
    target = normalize_target(action_target)
    unless runner_names.include?(target)
      return [false, "대상을 찾을 수 없습니다. 아이디 또는 크리쳐 이름을 확인해주세요."]
    end

    target_runner = runner_state.find { |r| r[:name] == target }
    return [false, "대상을 찾을 수 없습니다. 아이디 또는 크리쳐 이름을 확인해주세요."] unless target_runner

  when '이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase

    unless coord.match?(/^[A-G][1-8]$/)
      return [false, "이동 좌표가 올바르지 않습니다. A1~G8 범위로 입력해주세요."]
    end

  else
    return [false, "형식이 올바르지 않습니다. [공격/크리쳐], [회복/아이디], [방어/아이디], [이동/좌표] 중 하나로 입력해주세요."]
  end

  [true, nil]
end

# ── 라운드 정산: 회복 → 방어 → 공격 → 크리쳐 반격 ──
def settle_round(battle_actions, runner_names, creature_sheet, view_sheet, creature)
  runner_state = view_sheet.read_runner_state
  base_stats   = creature_sheet.read_base_stats
  stats_of = ->(name) { base_stats.find { |s| s[:name] == name } || {} }
  state_of = ->(name) { runner_state.find { |r| r[:name] == name } }

  defended = {}
  log = []

  # 1) 회복
  battle_actions.each do |name, act|
    next unless act[:type] == '회복'
    target_name = normalize_target(act[:target])
    target = state_of.call(target_name)
    next unless target
    if target[:hp].to_i <= 0
      log << "#{name} → #{target_name} 회복 실패 (이미 쓰러짐)"
      next
    end
    heal = [stats_of.call(name)[:atk].to_i, 1].max
    before = target[:hp].to_i
    target[:hp] = [before + heal, target[:max_hp].to_i].min
    log << "#{name} → #{target_name} 회복 +#{target[:hp] - before}"
  end

  # 2) 방어
  battle_actions.each do |name, act|
    next unless act[:type] == '방어'
    target_name = normalize_target(act[:target])
    defended[target_name] = true
    log << "#{name} → #{target_name} 방어 (받는 피해 절반)"
  end

  # 3) 공격
  battle_actions.each do |name, act|
    next unless act[:type] == '공격'
    next if creature[:hp].to_i <= 0
    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)

    unless BattleCalculator.hit?(s[:tec].to_i)
      log << "#{name}의 공격 → 빗나감!"
      next
    end
    if BattleCalculator.evade?(creature[:agi].to_i)
      log << "#{name}의 공격 → #{creature[:name]} 회피!"
      next
    end

    crit = BattleCalculator.critical?(s[:luck].to_i)
    base = crit ? s[:atk].to_i * 2 : s[:atk].to_i
    dmg  = BattleCalculator.calc_damage(base, creature[:dur].to_i)
    creature[:hp] = [creature[:hp].to_i - dmg, 0].max
    log << "#{name}의 공격 → #{creature[:name]}에게 #{dmg} 피해#{crit ? ' (크리티컬!)' : ''}"
  end

  # 4) 크리쳐 반격
  if creature[:hp].to_i > 0
    living = runner_state.select { |r| r[:hp].to_i > 0 && runner_names.include?(r[:name]) }
    if living.any?
      target = living.sample
      ts = stats_of.call(target[:name])

      unless BattleCalculator.hit?(creature[:tec].to_i)
        log << "#{creature[:name]}의 반격 → 빗나감!"
      else
        if BattleCalculator.evade?(ts[:agi].to_i)
          log << "#{creature[:name]}의 반격 → #{target[:name]} 회피!"
        else
          crit = BattleCalculator.critical?(creature[:luck].to_i)
          base = crit ? creature[:atk].to_i * 2 : creature[:atk].to_i
          dmg  = BattleCalculator.calc_damage(base, ts[:dur].to_i)
          dmg  = dmg / 2 if defended[target[:name]]
          target[:hp] = [target[:hp].to_i - dmg, 0].max
          line = "#{creature[:name]}의 반격 → #{target[:name]}에게 #{dmg} 피해#{crit ? ' (크리티컬!)' : ''}"
          line += " [방어됨]" if defended[target[:name]]
          log << line
          if target[:hp] <= 0
            target[:status] = '사망'
            log << "#{target[:name]} 쓰러짐..."
          end
        end
      end
    end
  end

  view_sheet.update_runner_state(runner_state)
  [log, runner_state]
end

def build_result_text(runner_tags, battle_round, creature, battle_actions, runner_names, log, runner_state, view_sheet, timeout: false)
  creature_name   = creature[:name] || '크리쳐'
  creature_hp     = creature[:hp].to_i
  creature_max_hp = (creature[:max_hp] || creature_hp).to_i

  title = timeout ? "[#{battle_round}라운드] #{creature_name} 전투 결과 (시간 초과)" : "[#{battle_round}라운드] #{creature_name} 전투 결과"

  result = "#{runner_tags}\n\n#{title}\n\n"
  result += "───────────────────\n"

  runner_names.each do |name|
    action = battle_actions[name]
    if action
      result += "#{name}: [#{action[:type]}/#{action[:target]}]\n"
    else
      result += "#{name}: 턴 상실\n"
    end
  end

  result += "───────────────────\n"
  log.each { |l| result += "#{l}\n" }
  result += "───────────────────\n"

  runner_state.select { |r| runner_names.include?(r[:name]) }.each do |r|
    result += "#{r[:name]}: #{view_sheet.health_bar(r[:hp], r[:max_hp])}\n"
  end
  result += "#{creature_name}: #{view_sheet.health_bar(creature_hp, creature_max_hp)}\n\n"

  if creature_hp <= 0
    result += "#{creature_name} 격파! 전투 승리!"
  elsif runner_state.none? { |r| runner_names.include?(r[:name]) && r[:hp].to_i > 0 }
    result += "전원 전투 불능... 전투 패배..."
  else
    result += "#{ROUND_WAIT_SECONDS}초 후 다음 라운드가 시작됩니다."
  end

  result
end

# ── 재시작 시 과거 툿 재처리 방지: 현재 타임라인/DM을 처리 완료로 스냅샷 ──
fetch_public_statuses.each { |s| processed_statuses.add(s['id']) if s['id'] }
snapshot_current_dm_ids(processed_dm_ids)
puts "[전투봇] 기존 툿 스냅샷 완료 (재발동 방지)"

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

    conversations = fetch_conversations

    # ── DM으로 전투시작/전투종료 (테스트 모드) ──
    conversations.each do |conv|
      sender = conv['accounts'].first
      next unless sender

      last_status = conv['last_status']
      next unless last_status

      dm_id = last_status['id']
      next if processed_dm_ids.include?(dm_id)

      content = clean_html(last_status['content'])

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

        battle_creature = current_creature(creature_sheet)
        battle_creature[:pos] = 'D4' if battle_creature[:pos].to_s.strip.empty?
        view_sheet.update_creature_state(battle_creature)

        processed_dm_ids.add(dm_id)
        snapshot_current_dm_ids(processed_dm_ids)

        puts "[전투봇] (DM 테스트) #{battle_round}라운드 시작 - 참여자 #{total_runners}명 (#{runner_names.join(', ')}), 상대: #{battle_creature[:name]}"

      elsif content.include?('[전투종료]') && battle_active
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        auto_next_round_timer = nil
        battle_creature = nil

        broadcast.call("#{runner_tags}\n\n[전투 강제 종료]")
        processed_dm_ids.add(dm_id)
        dm_mode = false
        puts "[전투봇] 전투 종료 (DM)"
      end
    end

    # ── 공개 타임라인 전투시작/전투종료 (기존 방식) ──
    fetch_public_statuses.each do |status|
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

        dm_mode = false
        battle_active = true
        battle_announced = false
        battle_start_time = Time.now
        battle_round = content.match(/\[(\d+)\]/)&.[](1) || "1"
        battle_actions = {}
        processed_messages = {}
        snapshot_current_dm_ids(processed_dm_ids)
        auto_next_round_timer = nil

        battle_creature = current_creature(creature_sheet)
        battle_creature[:pos] = 'D4' if battle_creature[:pos].to_s.strip.empty?
        view_sheet.update_creature_state(battle_creature)

        puts "[전투봇] #{battle_round}라운드 시작 - 참여자 #{total_runners}명 (#{runner_names.join(', ')}), 상대: #{battle_creature[:name]}"

      elsif content.include?('[전투종료]')
        was_active = battle_active
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        auto_next_round_timer = nil
        battle_creature = nil

        broadcast.call(dm_mode && was_active ? "#{runner_tags}\n\n[전투 강제 종료]" : "[전투 강제 종료]")
        dm_mode = false
        puts "[전투봇] 전투 종료"
      end

      processed_statuses.add(status_id)
    end

    if battle_active
      battle_creature ||= current_creature(creature_sheet)

      unless battle_announced
        announcement = "#{runner_tags}\n\n[#{battle_round}라운드] #{battle_creature[:name]}와의 전투!\n" \
                       "#{battle_creature[:name]} 상태: #{view_sheet.health_bar(battle_creature[:hp], battle_creature[:max_hp])}\n\n" \
                       "───────────────────\n" \
                       "DM으로 행동을 입력해주세요.\n\n" \
                       "형식:\n" \
                       "  [공격/크리쳐]\n" \
                       "  [회복/아이디]\n" \
                       "  [방어/아이디]\n" \
                       "  [이동/좌표]\n\n" \
                       "입력 대기: 5분\n" \
                       "───────────────────"

        broadcast.call(announcement)
        battle_announced = true

        puts "[전투봇] #{battle_round}라운드 안내 송출#{dm_mode ? ' (DM)' : ''}"
      end

      conversations.each do |conv|
        sender = conv['accounts'].first
        next unless sender

        username = sender['username']
        next unless runner_names.include?(username)

        last_status = conv['last_status']
        next unless last_status

        dm_id = last_status['id']
        next if processed_dm_ids.include?(dm_id)

        text = clean_html(last_status['content'])
        next if text.include?('[전투시작]') || text.include?('[전투종료]')

        if processed_messages[username]
          listener.send_dm(username, "이미 이번 라운드 행동을 제출했습니다.")
          processed_dm_ids.add(dm_id)
          next
        end

        match = text.match(/\[(공격|회복|방어|이동)\/(.+?)\]/)

        unless match
          listener.send_dm(username, "형식이 올바르지 않습니다. [공격/크리쳐], [회복/아이디], [방어/아이디], [이동/좌표] 중 하나로 입력해주세요.")
          processed_dm_ids.add(dm_id)
          next
        end

        action_type = match[1]
        action_target = match[2].strip

        valid, error_message = validate_action(username, action_type, action_target, runner_names, view_sheet, battle_creature)

        unless valid
          listener.send_dm(username, error_message)
          processed_dm_ids.add(dm_id)
          next
        end

        if action_type == '이동'
          coord = LOCATION_MAP[action_target] || action_target
          coord = coord.to_s.strip.upcase

          runner_state = view_sheet.read_runner_state
          runner = runner_state.find { |r| r[:name] == username }

          if runner
            runner[:pos] = coord
            view_sheet.update_runner_state(runner_state)
            view_sheet.update_creature_state(battle_creature)
            puts "[전투봇] #{username} 이동 → #{coord}"
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
      end

      round_done = battle_actions.size >= total_runners && total_runners > 0
      round_timeout = (Time.now - battle_start_time) >= ACTION_WAIT_SECONDS

      if round_done || round_timeout
        log, runner_state = settle_round(battle_actions, runner_names, creature_sheet, view_sheet, battle_creature)
        view_sheet.update_creature_state(battle_creature) if battle_creature[:hp].to_i > 0

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

        broadcast.call(result)

        battle_active = false

        creature_dead = battle_creature[:hp].to_i <= 0
        all_runners_dead = runner_state.none? { |r| runner_names.include?(r[:name]) && r[:hp].to_i > 0 }

        if creature_dead || all_runners_dead
          auto_next_round_timer = nil
          battle_creature = nil
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

  sleep(10)
end
