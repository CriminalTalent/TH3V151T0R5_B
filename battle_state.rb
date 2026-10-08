# battle_state.rb
# encoding: UTF-8

def truthy_value?(value)
  text = value.to_s.strip.upcase
  value == true || text == 'TRUE' || text == '1' || text == 'ON' || text == 'YES' || text == 'Y' || text == '✓' || text == '✔'
end

def parse_creature_stats_row(row)
  # 크리쳐 시트 / 스탯 탭 간소화 구조:
  # A 활성
  # B 이름
  # C 위치
  # D 크기
  # E 현재스킬
  # F 건강
  # G 내구도
  # H 마법능력
  # I 민첩
  # J 기술
  # K 행운
  # L 비고
  # M 보상크레딧 (처치 시 파티 전원에게 지급, 비어있으면 0)
  name = row[1].to_s.strip
  return nil if name.empty?

  hp = row[5].to_i
  hp = 200 if hp <= 0

  current_skill = row[4].to_s.strip
  reward_raw = row[12].to_s.strip
  reward = reward_raw.match?(/\A-?\d+\z/) ? reward_raw.to_i : 0

  # 전투봇 격자는 A~G, 1~8 범위뿐이다. 조사맵 좌표(H~O 등) 같이 범위 밖 값이
  # 잘못 들어와 있으면 사거리/이동 계산이 깨지므로 기본값(D4)으로 보정한다.
  raw_pos = row[2].to_s.strip.upcase
  pos = raw_pos.match?(/\A[A-G][1-8]\z/) ? raw_pos : 'D4'
  puts "[전투봇] 크리쳐 '#{name}' 위치 '#{raw_pos}'가 전투 격자 범위(A~G,1~8) 밖이라 D4로 보정했습니다." if !raw_pos.empty? && pos != raw_pos

  {
    name:    name,
    pos:     pos,
    size:    row[3].to_s.strip.downcase.empty? ? '1x1' : row[3].to_s.strip.downcase,
    hp:      hp,
    max_hp:  hp,
    dur:     row[6].to_i,
    atk:     row[7].to_i,
    agi:     row[8].to_i,
    tec:     row[9].to_i,
    luck:    row[10].to_i,
    hit_base:   row[13].to_s.strip.empty? ? 60 : row[13].to_i,
    evade_base: row[14].to_s.strip.empty? ? 0 : row[14].to_i,
    facing:     ['상', '하', '좌', '우'].include?(row[15].to_s.strip) ? row[15].to_s.strip : '하',
    current_skill: current_skill,
    pattern: current_skill,
    skill_target: '',
    skill_range: '',
    pattern_cells: '',
    debuff: '',
    cells: '',
    pattern_multiplier: '',
    pattern_cooldown: '',
    note: row[11].to_s.strip,
    reward: reward,
    status: ''
  }
end

# ──────────────────────────────────────────────
# 보스스킬 시트 캐시
#
# 보스스킬 탭은 전투 중 값이 바뀌지 않는 정적 정의 데이터인데,
# 예전에는 boss_skill_defined?/read_boss_skill_definition이 호출될 때마다
# (라운드 안내, 보스행동커맨드 파싱 등에서 매우 자주 호출됨) 매번 시트를
# 새로 읽어와 구글 시트 API 할당량 소모의 큰 원인이 되었다.
# 봇 프로세스가 살아있는 동안은 1회만 읽고 메모리에 캐시한다.
# 운영 중 보스스킬 탭을 직접 수정했다면 봇을 재시작하거나,
# 관리자 명령으로 $boss_skill_cache = nil 처리 후 재호출하면 다시 로드된다.
# ──────────────────────────────────────────────
$boss_skill_cache = nil

def load_boss_skill_cache!(creature_sheet)
  rows = creature_sheet.read('보스스킬!A2:L300') rescue []
  $boss_skill_cache = rows
  puts "[전투봇] 보스스킬 캐시 로드 완료 (#{rows.size}행)"
  rows
end

def boss_skill_rows(creature_sheet)
  $boss_skill_cache ||= load_boss_skill_cache!(creature_sheet)
end

# 보스스킬 탭 최종 구조:
# A 스킬명, B 분류, C 범위, D 쿨타임, E 배율, F 디버프,
# G 피해공식, H 범위형태, I 이동회피, J 대상수, K 설명, L 전조
def read_boss_skill_definition(creature_sheet, skill_name)
  skill_name = skill_name.to_s.strip
  return {} if skill_name.empty? || skill_name == '-'

  row = boss_skill_rows(creature_sheet).find { |r| r[0].to_s.strip == skill_name }
  return {} unless row

  {
    skill_name:     row[0].to_s.strip,
    skill_category: row[1].to_s.strip,
    skill_range_default: row[2].to_s.strip,
    skill_cooldown_default: row[3].to_s.strip,
    skill_multiplier_default: row[4].to_s.strip,
    skill_debuff_default: row[5].to_s.strip,
    damage_formula: row[6].to_s.strip,
    range_shape:    row[7].to_s.strip,
    dodgeable:      row[8].to_s.strip,
    target_count:   row[9].to_s.strip,
    skill_desc:     row[10].to_s.strip,
    omen:           row[11].to_s.strip
  }
rescue => e
  puts "[전투봇] 보스스킬 읽기 실패: #{e.class}: #{e.message}"
  {}
end

def apply_boss_skill_definition!(creature, creature_sheet)
  skill_name = creature[:current_skill].to_s.strip
  skill_name = creature[:pattern].to_s.strip if skill_name.empty?
  definition = read_boss_skill_definition(creature_sheet, skill_name)
  return creature if definition.empty?

  creature.merge!(definition)

  # 스탯 탭에서는 현재스킬만 운영하고, 세부값은 보스스킬 탭 기본값을 사용합니다.
  creature[:pattern_multiplier] = definition[:skill_multiplier_default] if creature[:pattern_multiplier].to_s.strip.empty?
  creature[:debuff] = definition[:skill_debuff_default] if creature[:debuff].to_s.strip.empty?
  creature[:pattern_cooldown] = definition[:skill_cooldown_default] if creature[:pattern_cooldown].to_s.strip.empty?

  # 보스스킬 탭 범위가 좌표 목록이면 패턴 좌표로 사용합니다.
  # 숫자 범위는 battle_boss_patterns.rb에서 보스 점유칸 기준 거리로 처리합니다.
  if creature[:skill_range].to_s.strip.empty?
    range_default = definition[:skill_range_default].to_s.strip
    if BattleGrid.parse_cell_list(range_default).any?
      creature[:skill_range] = range_default
      creature[:pattern_cells] = range_default
    end
  end

  creature
end

# 라운드 안내 시점에 스탯 탭 E열(현재스킬)과 보스스킬 탭 정의를 다시 읽어 반영합니다.
# (체력/위치 등 전투 진행 상태는 세션 값을 유지)
def refresh_creature_skill!(creature, creature_sheet)
  name = creature[:name].to_s.strip
  return creature if name.empty?

  latest = creature_from_stats_sheet_by_name(creature_sheet, name)
  if latest
    creature[:current_skill] = latest[:current_skill]
    creature[:pattern]       = latest[:current_skill]
  end

  # 이전 스킬 정의가 남지 않도록 스킬 관련 필드 초기화 후 재적용
  [:skill_target, :skill_range, :pattern_cells, :debuff, :pattern_multiplier,
   :pattern_cooldown, :skill_category, :range_shape, :damage_formula,
   :dodgeable, :target_count, :skill_desc, :omen, :skill_range_default,
   :skill_multiplier_default, :skill_debuff_default, :skill_cooldown_default].each do |key|
    creature[key] = ''
  end

  apply_boss_skill_definition!(creature, creature_sheet)
rescue => e
  puts "[전투봇] 크리쳐 스킬 갱신 실패: #{e.class}: #{e.message}"
  creature
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
  row ||= rows.find { |r| r[1].to_s.gsub(/\s+/, '') == target.gsub(/\s+/, '') }
  return nil unless row
  parse_creature_stats_row(row)
rescue => e
  puts "[전투봇] 크리쳐 스탯 이름 검색 실패: #{e.class}: #{e.message}"
  nil
end

# 크리쳐 스탯 탭 간소화 구조용.
# 위치/크기는 스탯 탭 C/D열에서 읽고, 점유칸은 기본적으로 크기에서 자동 계산합니다.
def attach_creature_size_from_sheet(creature, creature_sheet)
  name = creature[:name].to_s.strip
  return creature if name.empty?

  # active_creature_from_stats_sheet / creature_from_stats_sheet_by_name을 거쳐
  # parse_creature_stats_row로 이미 pos/size가 정상 채워진 경우, 같은 스탯 탭을
  # 다시 읽는 건 완전히 중복 호출이라 건너뛴다. (fallback 경로처럼 pos/size가
  # 없는 경우에만 실제로 재조회한다)
  already_loaded = creature[:pos].to_s.match?(/\A[A-G][1-8]\z/) && !creature[:size].to_s.strip.empty?
  return creature if already_loaded

  rows = creature_sheet.read('스탯!A2:Z100') rescue []
  row = rows.find do |r|
    r[1].to_s.strip == name || r[0].to_s.strip == name
  end

  if row
    pos_cell = row[2].to_s.strip.upcase
    creature[:pos] = pos_cell if pos_cell.match?(/\A[A-G][1-8]\z/)

    size_cell = row[3].to_s.strip
    creature[:size] = size_cell.downcase unless size_cell.empty?
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
  return apply_boss_skill_definition!(attach_creature_size_from_sheet(active, creature_sheet), creature_sheet) if active

  config = creature_sheet.read_creature_config || { name: '크리쳐', pos: nil }
  stats  = creature_from_stats_sheet_by_name(creature_sheet, config[:name]) || creature_sheet.read_creature_stats(config[:name]) || {
    name: config[:name] || '크리쳐',
    hp: 200,
    max_hp: 200,
    pos: 'D4',
    size: '1x1'
  }
  stats[:pos] = config[:pos] if config[:pos].to_s.match?(/^[A-G][1-8]$/)
  apply_boss_skill_definition!(attach_creature_size_from_sheet(stats, creature_sheet), creature_sheet)
end

# [현상금/크리쳐이름/판돈] 형식 파싱. 매치 안 되면 nil.
def bounty_start_match(content)
  content.to_s.match(/\[현상금\/([^\/\]]+?)\/(\d+)\]/i)
end

def creature_from_start_content(content, creature_sheet)
  # [현상금/크리쳐명/판돈] 형식도 크리쳐명 파싱 대상에 포함시킨다.
  bounty_match = bounty_start_match(content)

  # [전투시작/크리쳐명] 또는 [전투시작/크리쳐명/위치] 형식 우선 파싱
  slash_match = content.to_s.match(/\[전투시작\/([^\/\]]+?)(?:\/([A-G][1-8]))?\]/i)
  name       = bounty_match ? bounty_match[1] : slash_match&.[](1)
  inline_pos = slash_match&.[](2)

  name = content.to_s.match(/크리쳐\s*[「『](.+?)[」』]\s*출현/)&.[](1) if name.to_s.strip.empty?
  name = content.to_s.match(/상대[:：]\s*([^\n]+)/)&.[](1) if name.to_s.strip.empty?
  name = name.to_s.strip

  pos = inline_pos.to_s.strip
  pos = content.to_s.match(/위치[:：]\s*([A-G][1-8])/i)&.[](1).to_s if pos.empty?
  pos = content.to_s.match(/@\s*([A-G][1-8])/i)&.[](1).to_s if pos.strip.empty?
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
    hit_base: 60,
    evade_base: 0,
    facing: '하',
    pos: 'D4',
    size: '1x1',
    status: ''
  }

  stats[:name] = name unless name.empty? || name == '크리쳐'
  stats[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
  stats[:size] = size unless size.empty?
  stats[:cells] = cells unless cells.empty?

  # 현상금 사냥: hp/max_hp/atk를 2배로 강화한다.
  if bounty_match
    stats[:hp] = stats[:hp].to_i * 2
    stats[:max_hp] = stats[:max_hp].to_i * 2
    stats[:atk] = stats[:atk].to_i * 2
  end

  apply_boss_skill_definition!(attach_creature_size_from_sheet(stats, creature_sheet), creature_sheet)
rescue => e
  puts "[전투봇] 전투시작문 크리쳐 파싱 실패: #{e.class}: #{e.message}"
  current_creature(creature_sheet)
end

def build_fallback_runner_state(runner_names, runner_sheet, default_pos)
  base_stats = runner_sheet.read_base_stats

  runner_names.map do |name|
    stat = base_stats.find { |s| s[:name].to_s.casecmp?(name.to_s) || s[:id].to_s.casecmp?(name.to_s) }
    hp = stat ? [stat[:hp].to_i, 0].max : 50
    max_hp = stat && stat[:max_hp].to_i > 0 ? stat[:max_hp].to_i : hp

    {
      name:         name,
      display_name: stat && stat[:display_name],
      pos:          'D3',
      hp:           hp,
      max_hp:       max_hp,
      status:       '',
      facing:       stat && stat[:facing].to_s.strip.empty? == false ? stat[:facing] : '하'
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
  runner_names = runner_names.map(&:to_s).uniq

  current = view_sheet.read_runner_state
  current = [] unless current.is_a?(Array)

  # 같은 이름의 중복 행 제거 (첫 행 우선)
  seen = {}
  current = current.select do |r|
    key = r[:name].to_s
    next false if key.empty?
    next false if seen[key]
    seen[key] = true
    true
  end

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

def targetless_attack_skill?(action_type)
  ['폭발', '전체공격'].include?(action_type.to_s)
end

def validate_action(username, action_type, action_target, runner_names, view_sheet, runner_sheet, creature, positions: nil, battle_actions: nil)
  runner_state = merge_runner_state(
    view_sheet,
    runner_sheet,
    runner_names,
    creature[:pos]
  )

  # 준비 라운드 또는 이전 행동에서 세션에 저장된 실제 좌표를
  # 시트에서 읽은 좌표보다 우선해 검증에 사용합니다.
  if positions.is_a?(Hash)
    runner_state.each do |runner|
      runner_name = runner[:name].to_s

      pos = positions[runner_name]
      pos = positions[runner_name.to_sym] if pos.nil?

      pos = pos.to_s.strip.upcase
      runner[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
    end
  end

  actor = runner_state.find do |runner|
    runner[:name].to_s == username.to_s
  end

  unless runner_alive?(actor)
    puts "[전투봇] 행동 불가: @#{username}, actor=#{actor.inspect}, runner_names=#{runner_names.inspect}"
    return [false, '현재 행동할 수 없는 상태입니다.']
  end

  if action_type == '순간이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase
    ok, msg = BattleGrid.movable?(actor[:pos], coord, runner_state, creature, actor_name: username, teleport: true)
    return [false, msg] unless ok
    return [true, nil]
  end

  skill = BattleSkills.get(action_type)
  return [false, '알 수 없는 행동입니다.'] unless skill

  # 크리쳐(보스) 전용 스킬은 러너가 사용할 수 없습니다.
  if ['지정공격1인', '지정공격다인', '범위공격', '전체공격'].include?(action_type.to_s)
    return [false, "#{action_type}은(는) 크리쳐 전용 스킬입니다."]
  end

  parts = skill_target_parts(action_target)
  target = normalize_target(parts[0])

  if BattleSkills.attack?(action_type)
    creature_name = creature[:name].to_s

    # 대상 생략 공격 스킬은 현재 크리쳐를 대상으로 간주합니다.
    target = creature_name if target.empty? && targetless_attack_skill?(action_type)

    # 크리쳐 이름은 공백을 무시하고 비교합니다. (감시자1 == 감시자 1)
    same_creature = ['크리쳐', creature_name].include?(target) ||
                    (!target.empty? && target.gsub(/\s+/, '') == creature_name.gsub(/\s+/, ''))
    target = creature_name if same_creature

    unless same_creature || BattleGrid.valid_pos?(target)
      return [false, "대상을 찾을 수 없습니다. [#{action_type}/#{creature_name}] 형식으로 입력해주세요."]
    end

    unless BattleGrid.in_range?(actor[:pos], target, skill[:range], creature: creature)
      return [false, "#{action_type}의 사거리 밖입니다. 현재 위치: #{actor[:pos]}, 대상: #{target}"]
    end
    # 습격은 최종적으로 머무는 좌표(parts[1])가 크리쳐 바로 옆(1칸 이내)이어야 합니다.
    if skill[:kind] == :rush
      rush_dest = parts[1].to_s.strip.upcase
      unless BattleGrid.valid_pos?(rush_dest)
        return [false, '이동할 좌표가 올바르지 않습니다. 예: [습격/크리쳐이름/D4]']
      end
      rush_dist = BattleGrid.distance_to_creature(rush_dest, creature)
      if rush_dist.nil? || rush_dist > 1
        return [false, "습격은 #{creature_name} 바로 옆(1칸 이내)에 머무는 좌표만 지정할 수 있습니다. 지정 좌표: #{rush_dest}"]
      end
      unless BattleGrid.straight_line?(actor[:pos], rush_dest)
        return [false, "습격은 현재 위치(#{actor[:pos]})에서 가로/세로/대각선 직선상에 있는 좌표로만 이동할 수 있습니다. 지정 좌표: #{rush_dest}"]
      end
    end
  elsif BattleSkills.support?(action_type) || BattleSkills.defense?(action_type)
    # 범위형(사거리 내 전원 적용) 스킬은 인물 지정이 필요 없습니다.
    area_skill = [:heal_area, :atk_buff_area, :dur_buff_area, :agi_buff_area].include?(skill[:kind])

    # 자신 대상 스킬, 범위형 스킬, 방어(미지정 시 자신)는 대상 생략 허용.
    target = username if target.empty? && (skill[:range].to_s == '자신' || area_skill || skill[:kind] == :dur_guard)

    # 다중 대상(콤마 구분) 지원: 첫 대상 기준으로 검증
    first_target = target.to_s.split(',').map { |t| normalize_target(t) }.reject(&:empty?).first.to_s
    target_runner = target_runner_by_name(runner_state, first_target)

    # 행운부여/범위 좌표 지정류는 좌표를 허용.
    if skill[:kind] == :force_move
      return [false, '대상과 이동 좌표가 필요합니다. 예: [행운부여/Test2/C3]'] unless target_runner && parts[1]
      return [false, '이동 좌표가 올바르지 않습니다.'] unless BattleGrid.valid_pos?(parts[1])
    elsif !target_runner && !['-', '특정마스'].include?(skill[:range].to_s)
      return [false, '대상을 찾을 수 없습니다. 참여자 아이디를 확인해주세요.']
    end

    # 대상이 이번 라운드에 이미 습격을 접수해뒀다면, 사거리 판정을 습격의
    # 예상 도착 위치 기준으로 한다(습격이 지원 스킬보다 먼저 접수된 경우에만
    # 반영되며, 나중에 접수되면 이 시점엔 알 수 없어 기존 위치로 판정한다).
    if target_runner && battle_actions.is_a?(Hash)
      rush_act = battle_actions[target_runner[:name].to_s] || battle_actions[target_runner[:name].to_s.to_sym]
      if rush_act
        rush_skill = BattleSkills.get(rush_act[:type])
        if rush_skill && rush_skill[:kind] == :rush
          rush_parts = skill_target_parts(rush_act[:target])
          rush_dest = rush_parts[1].to_s.strip.upcase
          if BattleGrid.valid_pos?(rush_dest)
            landing = BattleGrid.rush_landing_cell(target_runner[:pos], rush_dest, runner_state, creature, actor_name: target_runner[:name])
            target_runner = target_runner.merge(pos: landing)
          end
        end
      end
    end

    if BattleItems.potion?(action_type)
      # 전투 중 물약: 사거리 제한 없음, 대상 1명만, 소지품 필요
      potion_targets = target.to_s.split(',').map(&:strip).reject(&:empty?)
      if potion_targets.size > 1
        return [false, "전투 중 #{action_type}은(는) 1명에게만 사용할 수 있습니다. 예: [#{action_type}/아이디]"]
      end
      if BattleItems.owned?(username, action_type) == false
        return [false, "소지품에 #{action_type}이(가) 없습니다."]
      end
    elsif target_runner && !BattleGrid.in_range?(actor[:pos], target_runner[:pos], skill[:range])
      return [false, "#{action_type}의 사거리 밖입니다. 현재 위치: #{actor[:pos]}, 대상 위치: #{target_runner[:pos]}"]
    end
  end

  [true, nil]
end

require_relative 'battle_items'

def command_pattern
  BattleSkills.command_regex
end

def record_battle_action(username, text, battle_actions, processed_messages, processed_id_set, processed_id, runner_names, view_sheet, runner_sheet, battle_creature, listener, ctx = nil)
  puts "[전투봇] 행동 수신: @#{username} -> #{text}"

  if processed_messages[username]
    puts "[전투봇] 중복 행동 무시: @#{username} -> #{text}"
    processed_id_set.add(processed_id)
    return
  end

  # 필사즉생 과잉피해로 인한 다음 라운드 행동 봉쇄. 잠금이 걸려 있으면
  # 어떤 명령을 보냈든 무조건 무효 처리하고 잠금을 소비(해제)한다.
  if ctx && ctx[:action_locked] && ctx[:action_locked][username]
    ctx[:action_locked].delete(username)
    battle_actions[username] = { type: '행동불가', target: '' }
    processed_messages[username] = true
    processed_id_set.add(processed_id)
    listener.send_dm(username, "[필사즉생] 과잉 피해로 인해 이번 라운드는 행동할 수 없습니다.") if listener
    puts "[전투봇] 행동 봉쇄: @#{username} → 필사즉생 과잉피해로 행동 불가"
    return
  end

  # [관찰]: 의도적으로 턴을 넘기는 명령. 행동 인원으로 집계되어 라운드 대기를 끝냅니다.
  # (슬리데린 패시브 2번은 관찰/미행동 시 다음 라운드부터 행운 +10)
  if text.match?(/\[관찰\]/)
    battle_actions[username] = { type: '관찰', target: '' }
    processed_messages[username] = true
    processed_id_set.add(processed_id)
    puts "[전투봇] 행동 등록 완료: #{username} → [관찰]"
    return
  end

  match = text.match(/\[(#{command_pattern}|순간이동)(?:\/(.+?))?\]/)

  unless match
    # 다중 태그, 안내문, 잡담처럼 전투 명령이 아닌 글은 조용히 무시합니다.
    # 단, 대괄호 명령처럼 보이는데 형식만 틀린 경우에만 안내합니다.
    if text.match?(/\[[^\]]+\]/)
      puts "[전투봇] 행동 형식 불일치: @#{username} -> #{text}"
      listener.send_dm(username, '형식이 올바르지 않습니다. [공격/보스이름], [스킬명/대상], [방어/아이디], [순간이동/좌표]  중 하나로 입력해주세요.')
    else
      puts "[전투봇] 비명령 메시지 무시: @#{username} -> #{text}"
    end
    processed_id_set.add(processed_id)
    return
  end

  action_type = match[1]
  action_target = normalize_target(match[2])

  # 쿨타임이 돌지 않은 스킬을 다시 쓰면 즉시 안내하고 행동으로 등록하지 않습니다.
  if ctx && action_type != '순간이동'
    skill = BattleSkills.get(action_type)
    if skill
      if skill[:once] && ctx[:once_used][username][action_type]
        puts "[전투봇] 1회성 스킬 재사용 차단: @#{username} -> #{action_type}"
        listener.send_dm(username, "[#{action_type}]은(는) 전투 중 1회만 사용할 수 있는 스킬입니다. 이미 사용했어요. 다른 행동을 입력해주세요.")
        processed_id_set.add(processed_id)
        return
      end

      left = ctx[:cooldowns][username][action_type].to_i
      if left > 0
        puts "[전투봇] 쿨타임 차단: @#{username} -> #{action_type} (#{left}라운드 남음)"
        listener.send_dm(username, "[#{action_type}]은(는) 아직 쿨타임 중입니다. (#{left}라운드 남음) 다른 행동을 입력해주세요.")
        processed_id_set.add(processed_id)
        return
      end

      # 즉발은 "정산 시점"이 아니라 "접수(입력) 시점"에 즉시 효과를 낸다.
      # 같은 라운드 안에서 대상이 곧바로 그 스킬을 다시 쓸 수 있어야 하는데,
      # 다른 스킬(쿨타임 체크)은 접수 시점에 이루어지므로 즉발도 접수 시점에
      # 쿨타임을 지워야 같은 라운드 내 재사용이 가능해진다.
      if skill[:kind] == :cooldown_reset
        reset_parts = action_target.to_s.split('/').map(&:strip).reject(&:empty?)
        reset_target_raw = reset_parts[0].to_s
        skill_to_reset = reset_parts[1].to_s

        if skill_to_reset.empty?
          puts "[전투봇] 즉발 즉시효과 무효 (스킬명 미입력): @#{username} -> #{action_target}"
        else
          reset_targets = reset_target_raw.split(',').map { |t| normalize_target(t) }.reject(&:empty?)
          reset_targets.each do |rt|
            ctx[:cooldowns][rt].delete(skill_to_reset)
          end
          puts "[전투봇] 즉발 즉시효과 적용: @#{username} -> #{reset_targets.join(', ')}의 [#{skill_to_reset}] 쿨타임 초기화"
        end
      end
    end
  end

  valid, error_message = validate_action(
    username,
    action_type,
    action_target,
    runner_names,
    view_sheet,
    runner_sheet,
    battle_creature,
    positions: ctx.is_a?(Hash) ? ctx[:positions] : nil,
    battle_actions: battle_actions
  )

  unless valid
    puts "[전투봇] 행동 검증 실패: @#{username} -> #{error_message}"
    listener.send_dm(username, error_message)
    processed_id_set.add(processed_id)
    return
  end

  action_meta = {}

  if action_type == '순간이동'
    coord = LOCATION_MAP[action_target] || action_target
    coord = coord.to_s.strip.upcase

    runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, battle_creature[:pos])
    runner = runner_state.find { |r| r[:name].to_s == username.to_s }

    if runner
      from_pos = runner[:pos].to_s.strip.upcase
      runner[:pos] = coord

      # 화면 시트와 세션 위치를 함께 갱신합니다.
      # 둘 중 하나만 갱신되면 다음 명령 검증에서 과거 좌표가
      # 현재 좌표를 다시 덮어쓸 수 있습니다.
      view_sheet.update_runner_state(runner_state)

      if ctx.is_a?(Hash)
        ctx[:positions] ||= {}
        ctx[:positions][username.to_s] = coord
      end

      action_meta[:from] = from_pos
      action_meta[:to] = coord

      puts "[전투봇] #{username} 순간이동 #{from_pos} → #{coord}"
    end
  end

  if BattleSkills.attack?(action_type) && action_target.to_s.strip.empty? && targetless_attack_skill?(action_type)
    action_target = battle_creature[:name].to_s
  end

  battle_actions[username] = {
    type: action_type,
    target: action_target
  }.merge(action_meta)

  processed_messages[username] = true
  processed_id_set.add(processed_id)

  puts "[전투봇] 행동 등록 완료: #{username} → [#{action_type}/#{action_target}]"
end

# 보스스킬 탭에 정의된 스킬명인지 확인 (공백 무시 비교 포함)
def boss_skill_defined?(creature_sheet, name)
  n = name.to_s.strip
  return false if n.empty?
  boss_skill_rows(creature_sheet).any? { |r| r[0].to_s.strip == n || r[0].to_s.gsub(/\s+/, '') == n.gsub(/\s+/, '') }
rescue
  false
end
