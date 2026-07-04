# battle_state.rb
# encoding: UTF-8

# 크리쳐 스탯 시트에서 크기 컬럼을 아직 못 읽는 구버전 sheet_manager 호환용.
# 스탯 탭에 '크기=3x1' 같은 텍스트가 어느 셀에 있으면 잡아냅니다.
def attach_creature_size_from_sheet(creature, creature_sheet)
  name = creature[:name].to_s.strip
  return creature if name.empty?

  rows = creature_sheet.read('스탯!A2:Z100') rescue []
  row = rows.find do |r|
    r[0].to_s.strip == name || r[1].to_s.strip == name
  end

  if row
    size_cell = row.find { |cell| cell.to_s.strip.match?(/\A\d+\s*x\s*\d+\z/i) }
    creature[:size] = size_cell.to_s.strip.downcase unless size_cell.to_s.strip.empty?
  end

  creature[:size] = '1x1' if creature[:size].to_s.strip.empty?
  creature
rescue => e
  puts "[전투봇] 크리쳐 크기 읽기 실패: #{e.class}: #{e.message}"
  creature[:size] ||= '1x1'
  creature
end

def current_creature(creature_sheet)
  config = creature_sheet.read_creature_config || { name: '크리쳐', pos: nil }
  stats  = creature_sheet.read_creature_stats(config[:name]) || {
    name: config[:name] || '크리쳐',
    hp: 200,
    max_hp: 200,
    pos: 'D4'
  }
  stats[:pos] = config[:pos] if config[:pos].to_s.match?(/^[A-G][1-8]$/)
  attach_creature_size_from_sheet(stats, creature_sheet)
end

def creature_from_start_content(content, creature_sheet)
  name = content.to_s.match(/크리쳐\s*[「『](.+?)[」』]\s*출현/)&.[](1)
  name = content.to_s.match(/상대[:：]\s*([^\n]+)/)&.[](1) if name.to_s.strip.empty?
  name = name.to_s.strip
  name = '크리쳐' if name.empty?

  pos = content.to_s.match(/위치[:：]\s*([A-G][1-8])/i)&.[](1)
  pos = content.to_s.match(/@\s*([A-G][1-8])/i)&.[](1) if pos.to_s.strip.empty?
  pos = pos.to_s.strip.upcase

  size = content.to_s.match(/크기[:=：]\s*(\d+\s*x\s*\d+)/i)&.[](1).to_s.strip.downcase

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
  stats[:size] = size unless size.empty?
  attach_creature_size_from_sheet(stats, creature_sheet)
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

def target_runner_by_name(runner_state, target)
  normalized = normalize_target(target)
  runner_state.find { |r| r[:name].to_s == normalized }
end

def skill_target_parts(raw)
  raw.to_s.split('/').map(&:strip).reject(&:empty?)
end

def validate_action(username, action_type, action_target, runner_names, view_sheet, runner_sheet, creature)
  runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, creature[:pos])
  actor = runner_state.find { |r| r[:name].to_s == username.to_s }

  unless runner_alive?(actor)
    puts "[전투봇] 행동 불가: @#{username}, actor=#{actor.inspect}, runner_names=#{runner_names.inspect}"
    return [false, '현재 행동할 수 없는 상태입니다.']
  end

  if action_type == '이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase
    ok, msg = BattleGrid.movable?(actor[:pos], coord, runner_state, creature, actor_name: username)
    return [false, msg] unless ok
    return [true, nil]
  end

  skill = BattleSkills.get(action_type)
  return [false, '알 수 없는 행동입니다.'] unless skill

  parts = skill_target_parts(action_target)
  target = normalize_target(parts[0])

  if BattleSkills.attack?(action_type)
    creature_name = creature[:name].to_s
    unless ['크리쳐', creature_name].include?(target) || BattleGrid.valid_pos?(target)
      return [false, "대상을 찾을 수 없습니다. [#{action_type}/크리쳐] 또는 [#{action_type}/#{creature_name}] 형식으로 입력해주세요."]
    end

    unless BattleGrid.in_range?(actor[:pos], target, skill[:range], creature: creature)
      return [false, "#{action_type}의 사거리 밖입니다. 현재 위치: #{actor[:pos]}, 대상: #{target}"]
    end
  elsif BattleSkills.support?(action_type) || BattleSkills.defense?(action_type)
    # 자신 대상 스킬은 대상 생략 허용.
    target = username if target.empty? && skill[:range].to_s == '자신'
    target_runner = target_runner_by_name(runner_state, target)

    # 행운부여/범위 좌표 지정류는 좌표를 허용.
    if skill[:kind] == :force_move
      return [false, '대상과 이동 좌표가 필요합니다. 예: [행운부여/Test2/C3]'] unless target_runner && parts[1]
      return [false, '이동 좌표가 올바르지 않습니다.'] unless BattleGrid.valid_pos?(parts[1])
    elsif !target_runner && !['-', '특정마스'].include?(skill[:range].to_s)
      return [false, '대상을 찾을 수 없습니다. 참여자 아이디를 확인해주세요.']
    end

    if target_runner && !BattleGrid.in_range?(actor[:pos], target_runner[:pos], skill[:range])
      return [false, "#{action_type}의 사거리 밖입니다. 현재 위치: #{actor[:pos]}, 대상 위치: #{target_runner[:pos]}"]
    end
  end

  [true, nil]
end

def command_pattern
  BattleSkills.command_regex
end

def record_battle_action(username, text, battle_actions, processed_messages, processed_id_set, processed_id, runner_names, view_sheet, runner_sheet, battle_creature, listener)
  puts "[전투봇] 행동 수신: @#{username} -> #{text}"

  if processed_messages[username]
    listener.send_dm(username, '이미 이번 라운드 행동을 제출했습니다.')
    processed_id_set.add(processed_id)
    return
  end

  match = text.match(/\[(#{command_pattern}|이동)\/(.+?)\]/)

  unless match
    puts "[전투봇] 행동 형식 불일치: @#{username} -> #{text}"
    listener.send_dm(username, '형식이 올바르지 않습니다. [공격/크리쳐], [스킬명/대상], [방어/아이디], [이동/좌표] 중 하나로 입력해주세요.')
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
  listener.send_dm(username, '확인, 대기해주세요.')
end
