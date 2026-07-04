# battle_state.rb
# encoding: UTF-8

def truthy_value?(value)
  text = value.to_s.strip.upcase
  value == true || text == 'TRUE' || text == '1' || text == 'ON' || text == 'YES' || text == 'Y' || text == '✓' || text == '✔'
end

def parse_creature_stats_row(row)
  # 크리쳐 시트 / 스탯 탭 현재 구조:
  # A 활성, B 이름, C 위치, D 크기, E 건강, F 내구도, G 마법능력, H 민첩, I 기술, J 행운, K 스킬1...
  name = row[1].to_s.strip
  return nil if name.empty?

  hp = row[4].to_i
  hp = 200 if hp <= 0

  # N 현재스킬/이번턴스킬, O 스킬대상, P 스킬범위, Q 디버프, R 점유칸, S 배율
  current_skill = row[13].to_s.strip
  skill_target  = row[14].to_s.strip
  skill_range   = row[15].to_s.strip
  debuff        = row[16].to_s.strip
  custom_cells  = row[17].to_s.strip
  multiplier    = row[18].to_s.strip

  # 구버전 호환: O열에 좌표 목록이 들어 있으면 스킬범위로도 사용합니다.
  legacy_range = skill_target if skill_target.upcase.scan(/[A-G][1-8]/).any?

  {
    name:    name,
    pos:     row[2].to_s.strip.upcase.empty? ? 'D4' : row[2].to_s.strip.upcase,
    size:    row[3].to_s.strip.downcase.empty? ? '1x1' : row[3].to_s.strip.downcase,
    hp:      hp,
    max_hp:  hp,
    dur:     row[5].to_i,
    atk:     row[6].to_i,
    agi:     row[7].to_i,
    tec:     row[8].to_i,
    luck:    row[9].to_i,
    skill1:  row[10].to_s.strip,
    skill2:  row[11].to_s.strip,
    facing:  row[12].to_s.strip,
    current_skill: current_skill,
    pattern: current_skill,
    skill_target: skill_target,
    skill_range: skill_range,
    pattern_cells: skill_range.empty? ? legacy_range.to_s : skill_range,
    debuff: debuff,
    cells: custom_cells,
    pattern_multiplier: multiplier,
    status:  ''
  }
end

def active_creature_from_stats_sheet(creature_sheet)
  rows = creature_sheet.read('스탯!A2:Z100') rescue []
  row = rows.find { |r| truthy_value?(r[0]) && !r[1].to_s.strip.empty? }
  return nil unless row
  parse_creature_stats_row(row)
rescue => e
  puts "[전투봇] 활성 크리쳐 스탯 읽기 실패: #{e.class}: #{e.message}"
  nil
end

def creature_from_stats_sheet_by_name(creature_sheet, creature_name)
  target = creature_name.to_s.strip
  return nil if target.empty?

  rows = creature_sheet.read('스탯!A2:Z100') rescue []
  row = rows.find { |r| r[1].to_s.strip == target }
  return nil unless row
  parse_creature_stats_row(row)
rescue => e
  puts "[전투봇] 크리쳐 스탯 이름 검색 실패: #{e.class}: #{e.message}"
  nil
end

# 크리쳐 스탯 시트에서 크기 컬럼을 아직 못 읽는 구버전 sheet_manager 호환용.
# 스탯 탭에 '크기=3x1' 같은 텍스트가 어느 셀에 있으면 잡아냅니다.
def attach_creature_size_from_sheet(creature, creature_sheet)
  name = creature[:name].to_s.strip
  return creature if name.empty?

  rows = creature_sheet.read('스탯!A2:Z100') rescue []
  row = rows.find do |r|
    r[1].to_s.strip == name || r[0].to_s.strip == name
  end

  if row
    size_cell = row[3].to_s.strip
    size_cell = row.find { |cell| cell.to_s.strip.match?(/\A\d+\s*x\s*\d+\z/i) }.to_s.strip if size_cell.empty?
    creature[:size] = size_cell.downcase unless size_cell.empty?

    # 임의 점유칸: A1 C6 G8 같은 식으로 입력 가능. H열은 7x8 규격 밖이라 무시됩니다.
    cell_text = row.find { |cell| cell.to_s.upcase.scan(/[A-Z][0-9]+/).any? }
    creature[:cells] ||= cell_text.to_s.strip if cell_text && cell_text.to_s !~ /\A\d+\s*x\s*\d+\z/i
  end

  creature[:size] = '1x1' if creature[:size].to_s.strip.empty?
  creature
rescue => e
  puts "[전투봇] 크리쳐 크기 읽기 실패: #{e.class}: #{e.message}"
  creature[:size] ||= '1x1'
  creature
end

def current_creature(creature_sheet)
  active = active_creature_from_stats_sheet(creature_sheet)
  return attach_creature_size_from_sheet(active, creature_sheet) if active

  config = creature_sheet.read_creature_config || { name: '크리쳐', pos: nil }
  stats  = creature_from_stats_sheet_by_name(creature_sheet, config[:name]) || creature_sheet.read_creature_stats(config[:name]) || {
    name: config[:name] || '크리쳐',
    hp: 200,
    max_hp: 200,
    pos: 'D4',
    size: '1x1'
  }
  stats[:pos] = config[:pos] if config[:pos].to_s.match?(/^[A-G][1-8]$/)
  attach_creature_size_from_sheet(stats, creature_sheet)
end

def creature_from_start_content(content, creature_sheet)
  name = content.to_s.match(/크리쳐\s*[「『](.+?)[」』]\s*출현/)&.[](1)
  name = content.to_s.match(/상대[:：]\s*([^\n]+)/)&.[](1) if name.to_s.strip.empty?
  name = name.to_s.strip

  pos = content.to_s.match(/위치[:：]\s*([A-G][1-8])/i)&.[](1)
  pos = content.to_s.match(/@\s*([A-G][1-8])/i)&.[](1) if pos.to_s.strip.empty?
  pos = pos.to_s.strip.upcase

  size = content.to_s.match(/크기[:=：]\s*(\d+\s*x\s*\d+)/i)&.[](1).to_s.strip.downcase
  cells = content.to_s.match(/(?:점유칸|칸|범위)[:=：]\s*([A-G][1-8](?:[ ,]+[A-G][1-8])*)/i)&.[](1).to_s.strip.upcase

  # [전투시작]에 크리쳐명이 없거나 '크리쳐'만 쓰였으면 활성 체크된 행을 우선 사용합니다.
  stats = if name.empty? || name == '크리쳐'
            current_creature(creature_sheet)
          else
            creature_from_stats_sheet_by_name(creature_sheet, name) || creature_sheet.read_creature_stats(name)
          end

  stats ||= {
    name: name.empty? ? '크리쳐' : name,
    hp: 200,
    max_hp: 200,
    dur: 10,
    atk: 10,
    agi: 0,
    tec: 0,
    luck: 0,
    pos: 'D4',
    size: '1x1',
    status: ''
  }

  stats[:name] = name unless name.empty? || name == '크리쳐'
  stats[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
  stats[:size] = size unless size.empty?
  stats[:cells] = cells unless cells.empty?
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
      pos:     'D3',
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
      pos:     'D3',
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
    puts "[전투봇] 중복 행동 무시: @#{username} -> #{text}"
    processed_id_set.add(processed_id)
    return
  end

  match = text.match(/\[(#{command_pattern}|이동)\/(.+?)\]/)

  unless match
    # 다중 태그, 안내문, 잡담처럼 전투 명령이 아닌 글은 조용히 무시합니다.
    # 단, 대괄호 명령처럼 보이는데 형식만 틀린 경우에만 안내합니다.
    if text.match?(/\[[^\]]+\]/)
      puts "[전투봇] 행동 형식 불일치: @#{username} -> #{text}"
      listener.send_dm(username, '형식이 올바르지 않습니다. [공격/보스이름], [스킬명/대상], [방어/아이디], [이동/좌표] 중 하나로 입력해주세요.')
    else
      puts "[전투봇] 비명령 메시지 무시: @#{username} -> #{text}"
    end
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

  action_meta = {}

  if action_type == '이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase

    runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, battle_creature[:pos])
    runner = runner_state.find { |r| r[:name].to_s == username.to_s }

    if runner
      from_pos = runner[:pos].to_s.strip.upcase
      runner[:pos] = coord
      view_sheet.update_runner_state(runner_state)
      action_meta[:from] = from_pos
      action_meta[:to] = coord
      puts "[전투봇] #{username} 이동 #{from_pos} → #{coord}"
    end
  end

  battle_actions[username] = {
    type: action_type,
    target: action_target
  }.merge(action_meta)

  processed_messages[username] = true
  processed_id_set.add(processed_id)

  puts "[전투봇] 행동 등록 완료: #{username} → [#{action_type}/#{action_target}]"
  listener.send_dm(username, '확인, 대기해주세요.')
end
