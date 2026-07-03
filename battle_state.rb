# encoding: UTF-8

def current_creature(creature_sheet)
  config = creature_sheet.read_creature_config || { name: '크리쳐', pos: nil }
  stats  = creature_sheet.read_creature_stats(config[:name]) || {
    name: config[:name] || '크리쳐',
    hp: 200,
    max_hp: 200,
    pos: 'D4'
  }
  stats[:pos] = config[:pos] if config[:pos].to_s.match?(/^[A-G][1-8]$/)
  stats
end

def creature_from_start_content(content, creature_sheet)
  name = content.to_s.match(/크리쳐\s*[「『](.+?)[」』]\s*출현/)&.[](1)
  name = content.to_s.match(/상대[:：]\s*([^\n]+)/)&.[](1) if name.to_s.strip.empty?
  name = name.to_s.strip
  name = '크리쳐' if name.empty?

  pos = content.to_s.match(/위치[:：]\s*([A-G][1-8])/i)&.[](1)
  pos = content.to_s.match(/@\s*([A-G][1-8])/i)&.[](1) if pos.to_s.strip.empty?
  pos = pos.to_s.strip.upcase

  stats = creature_sheet.read_creature_stats(name)
  stats = {
    name: name,
    hp: 200,
    max_hp: 200,
    dur: 10,
    atk: 10,
    agi: 0,
    tec: 0,
    luck: 0,
    pos: 'D4',
    status: ''
  } unless stats

  stats[:name] = name
  stats[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
  stats
rescue => e
  puts "[전투봇] 전투시작문 크리쳐 파싱 실패: #{e.class}: #{e.message}"
  current_creature(creature_sheet)
end

def build_fallback_runner_state(runner_names, runner_sheet, default_pos)
  base_stats = runner_sheet.read_base_stats

  runner_names.map do |name|
    stat = base_stats.find { |s| s[:name].to_s == name.to_s || s[:id].to_s == name.to_s }
    hp = stat ? stat[:hp].to_i : 50
    hp = 50 if hp <= 0

    {
      name:    name,
      pos:     default_pos.to_s.strip.empty? ? 'D4' : default_pos.to_s.strip.upcase,
      hp:      hp,
      max_hp:  hp,
      status:  '',
      facing:  stat && stat[:facing].to_s.strip.empty? == false ? stat[:facing] : '하'
    }
  end
rescue => e
  puts "[전투봇] fallback runner state 생성 실패: #{e.class}: #{e.message}"
  runner_names.map do |name|
    {
      name:    name,
      pos:     default_pos.to_s.strip.empty? ? 'D4' : default_pos.to_s.strip.upcase,
      hp:      50,
      max_hp:  50,
      status:  '',
      facing:  '하'
    }
  end
end

def merge_runner_state(view_sheet, runner_sheet, runner_names, default_pos)
  current = view_sheet.read_runner_state
  current = [] unless current.is_a?(Array)

  fallback = build_fallback_runner_state(runner_names, runner_sheet, default_pos)

  fallback.each do |base|
    found = current.find { |r| r[:name].to_s == base[:name].to_s }
    current << base unless found
  end

  current.select { |r| runner_names.include?(r[:name].to_s) }
end

def adjacent_move?(from, to)
  fc, fr = BattleCalculator.parse_pos(from.to_s.strip.upcase)
  tc, tr = BattleCalculator.parse_pos(to.to_s.strip.upcase)
  return true if fc.nil?
  return false if tc.nil?
  dx = (fc - tc).abs
  dy = (fr - tr).abs
  dx <= 1 && dy <= 1 && (dx + dy) > 0
end

def validate_action(username, action_type, action_target, runner_names, view_sheet, runner_sheet, creature)
  runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, creature[:pos])
  actor = runner_state.find { |r| r[:name].to_s == username.to_s }

  unless runner_alive?(actor)
    puts "[전투봇] 행동 불가: @#{username}, actor=#{actor.inspect}, runner_names=#{runner_names.inspect}"
    return [false, "현재 행동할 수 없는 상태입니다."]
  end

  case action_type
  when '공격'
    target = normalize_target(action_target)
    creature_name = creature[:name].to_s

    unless ['크리쳐', creature_name].include?(target)
      return [false, "대상을 찾을 수 없습니다. [공격/크리쳐] 또는 [공격/#{creature_name}] 형식으로 입력해주세요."]
    end

  when '회복', '방어'
    target = normalize_target(action_target)
    unless runner_names.include?(target)
      return [false, "대상을 찾을 수 없습니다. 참여자 아이디를 확인해주세요."]
    end

    target_runner = runner_state.find { |r| r[:name] == target }
    return [false, "대상을 찾을 수 없습니다. 참여자 아이디를 확인해주세요."] unless target_runner

  when '이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase

    unless coord.match?(/^[A-G][1-8]$/)
      return [false, "이동 좌표가 올바르지 않습니다. A1~G8 범위로 입력해주세요."]
    end

    unless adjacent_move?(actor[:pos], coord)
      return [false, "이동은 가로/세로/대각선으로 1칸만 가능합니다. (현재 위치: #{actor[:pos]})"]
    end

  else
    return [false, "형식이 올바르지 않습니다. [공격/크리쳐], [회복/아이디], [방어/아이디], [이동/좌표] 중 하나로 입력해주세요."]
  end

  [true, nil]
end

def record_battle_action(username, text, battle_actions, processed_messages, processed_id_set, processed_id, runner_names, view_sheet, runner_sheet, battle_creature, listener)
  puts "[전투봇] 행동 수신: @#{username} -> #{text}"

  if processed_messages[username]
    listener.send_dm(username, "이미 이번 라운드 행동을 제출했습니다.")
    processed_id_set.add(processed_id)
    return
  end

  match = text.match(/\[(공격|회복|방어|이동)\/(.+?)\]/)

  unless match
    puts "[전투봇] 행동 형식 불일치: @#{username} -> #{text}"
    listener.send_dm(username, "형식이 올바르지 않습니다. [공격/크리쳐], [회복/아이디], [방어/아이디], [이동/좌표] 중 하나로 입력해주세요.")
    processed_id_set.add(processed_id)
    return
  end

  action_type = match[1]
  action_target = normalize_target(match[2])

  valid, error_message = validate_action(username, action_type, action_target, runner_names, view_sheet, runner_sheet, battle_creature)

  unless valid
    puts "[전투봇] 행동 검증 실패: @#{username} -> #{error_message}"
    listener.send_dm(username, error_message)
    processed_id_set.add(processed_id)
    return
  end

  if action_type == '이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase

    runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, battle_creature[:pos])
    runner = runner_state.find { |r| r[:name].to_s == username.to_s }

    if runner
      runner[:pos] = coord
      view_sheet.update_runner_state(runner_state)
      # 현재 위치 시트에는 크리쳐/전투상태 탭이 없을 수 있으므로 메모리 상태만 사용합니다.
      puts "[전투봇] #{username} 이동 → #{coord}"
    end
  end

  battle_actions[username] = {
    type: action_type,
    target: action_target
  }

  processed_messages[username] = true
  processed_id_set.add(processed_id)

  puts "[전투봇] 행동 등록 완료: #{username} → [#{action_type}/#{action_target}]"
  listener.send_dm(username, "확인, 대기해주세요.")
end
