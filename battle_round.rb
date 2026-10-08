# battle_round.rb
# encoding: UTF-8

# 전투 정산 순서:
# 지원 → 방어 → 공격 → 크리쳐 반격

def stat_bonus(ctx, name, stat)
  ctx[:buffs][name].to_a.select { |b| b[:stat] == stat }.sum { |b| b[:value].to_i }
end
def cooldown_ready?(ctx, name, skill_name, skill)
  return true if skill[:once]
  cd = skill[:cooldown].to_i
  return true if cd <= 0
  ctx[:cooldowns][name][skill_name].to_i <= 0
end
def prepare_rush_moves!(battle_actions, runner_state, creature, ctx, state_of)
  moves = {}
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    next unless skill && skill[:kind] == :rush
    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    next unless cooldown_ready?(ctx, name, skill_name, skill)
    parts = skill_parts(act[:target])
    dest = parts[1].to_s.upcase
    next unless BattleGrid.valid_pos?(dest)
    old_pos = actor[:pos]
    dist = BattleGrid.distance(old_pos, dest).to_i
    multiplier = dist >= 5 ? skill[:long_multiplier] : skill[:multiplier]
    landing = BattleGrid.rush_landing_cell(old_pos, dest, runner_state, creature, actor_name: name)
    moved = landing != old_pos
    if moved
      actor[:pos] = landing
      (ctx[:positions] ||= {})[name.to_s] = landing
    end
    moves[name] = { old_pos: old_pos, dest: landing, multiplier: multiplier, moved: moved }
  end
  moves
end

def cleanup_buffs!(ctx)
  ctx[:buffs].each do |name, buffs|
    buffs.each { |b| b[:turns] = b[:turns].to_i - 1 if b[:turns] }
    ctx[:buffs][name] = buffs.reject { |b| b[:turns] && b[:turns] <= 0 }
  end
end

def advance_cooldowns!(ctx)
  ctx[:cooldowns].each do |_name, skills|
    skills.each_key { |sk| skills[sk] = skills[sk].to_i - 1 }
    skills.reject! { |_sk, left| left.to_i <= 0 }
  end
end

def skill_parts(raw)
  raw.to_s.split('/').map(&:strip).reject(&:empty?)
end

def split_targets(raw)
  raw.to_s.split(',').map { |t| normalize_target(t) }.reject(&:empty?)
end

def creature_target?(target, creature)
  ['크리쳐', creature[:name].to_s].include?(normalize_target(target)) || BattleGrid.valid_pos?(target)
end

def can_use_once?(ctx, name, skill_name)
  !ctx[:once_used][name][skill_name]
end

def mark_once!(ctx, name, skill_name)
  ctx[:once_used][name][skill_name] = true
end

# 쿨타임 게이트: 사용 가능하면 쿨타임을 기록하고 true, 쿨타임 중이면 false
def cooldown_gate!(ctx, log, name, skill_name, skill, dname = nil)
  return true if skill[:once]
  cd = skill[:cooldown].to_i
  return true if cd <= 0

  left = ctx[:cooldowns][name][skill_name].to_i
  if left > 0
    log << "#{dname || name}의 #{skill_name} → 쿨타임 #{left}라운드 남음 (행동 무효)"
    return false
  end

  ctx[:cooldowns][name][skill_name] = cd + 1
  true
end

# 크리쳐가 여러 칸을 차지할 때(예: 3x1), 공격 스킬의 사거리 안에 걸리는
# 칸 수만큼 배율을 곱한다. 사거리가 '-'/'전체'/'특정마스'/빈값이면 크리쳐가
# 차지한 칸 전부를 맞춘 것으로 간주. 습격은 자체 거리 배율(×1.5/×3.0) 체계가
# 이미 있어 이 계산 대상에서 제외한다(호출부에서 rush_attack이면 건너뜀).
def cells_hit_count(from_pos, range_text, creature)
  cells = BattleGrid.creature_cells(creature)
  return 1 if cells.empty?
  return [cells.size, 1].max if ['', '-', '전체', '특정마스'].include?(range_text.to_s.strip)

  is_close_range = range_text.to_s.strip == '근접'
  limit = is_close_range ? 1 : range_text.to_s.strip.to_i
  limit = 1 if limit <= 0

  # 근접(체비셰프)/숫자(맨해튼) 사거리 판정 방식을 in_range?와 동일하게 맞춘다.
  # (이전에는 항상 체비셰프 거리로 계산되어, 숫자 사거리 스킬의 실제 명중
  #  범위(다이아몬드)보다 훨씬 넓게(정사각형) 판정되는 문제가 있었다.)
  hit = cells.count do |cell|
    d = is_close_range ? BattleGrid.distance(from_pos, cell) : BattleGrid.manhattan(from_pos, cell)
    d.to_i <= limit
  end
  [hit, 1].max
end

def apply_damage_to_creature(log, creature, attacker_name, skill_name, atk_value, multiplier, dur, crit: false, guaranteed: false)
  before_hp = creature[:hp].to_i

  scaled = (atk_value.to_f * multiplier.to_f).ceil
  final_power = crit ? scaled * 2 : scaled
  dmg = BattleCalculator.calc_damage(final_power, dur.to_i)

  creature[:hp] = [before_hp - dmg, 0].max

  log << "#{attacker_name}의 #{skill_name}"
  log << ''
  log << "피해 계산"
  log << "공격력 #{atk_value.to_i}"
  log << "스킬 배율 ×#{multiplier.to_f}"
  log << "= #{scaled}"

  if crit
    log << ''
    log << "크리티컬 ×2"
    log << "= #{final_power}"
  end

  log << ''
  log << "내구도 #{dur.to_i}"
  log << ''
  log << "실질 피해 #{dmg}"
  log << ''
  log << "#{creature[:name]} HP"
  log << "#{before_hp} → #{creature[:hp]}"

  dmg
end

def settle_round(battle_actions, runner_names, runner_sheet, creature_sheet, view_sheet, creature, ctx)
  # 크리쳐가 이번 라운드 확정된 스킬로 러너 전용 지원/방어 스킬(흡수/철벽/
  # 방어/주의분산/자가치유 등)을 쓰기로 되어 있으면, 4)보스패턴(공격 전용)
  # 대신 러너와 동일한 1)지원/2)방어 처리 루프를 자기 자신을 대상으로 타도록
  # 한다. 단, "보스스킬" 탭에 그 스킬명이 실제로 등록되어 있을 때만 허용한다
  # (자동/수동 지정 모두 동일하게 적용) — 시트에 없으면 그냥 무시하고 기존
  # 4)보스패턴 경로로 진행한다.
  creature_skill_name = creature[:current_skill].to_s.strip
  creature_skill_def = BattleSkills.get(creature_skill_name)
  creature_boss_sheet_def = read_boss_skill_definition(creature_sheet, creature_skill_name)
  creature_uses_runner_skill = !!(
    creature_skill_def &&
    !BattleSkills.attack?(creature_skill_name) &&
    !creature_boss_sheet_def.empty?
  )
  # 보스스킬 탭의 배율(E열)이 지정되어 있으면 그 값을 쓴다(크리쳐마다 다른
  # 배율을 시트에서 조정 가능하게 함). BattleSkills::SKILLS(전역 상수)는
  # 건드리지 않고, ctx에 이번 라운드 한정 오버라이드 값만 저장해 아래
  # "1) 지원"/"2) 방어" 처리부에서 skill_name == creature_skill_name일 때만
  # 지역적으로 배율을 바꿔 쓴다.
  ctx[:creature_skill_ratio_override] = nil
  if creature_uses_runner_skill
    sheet_ratio = creature_boss_sheet_def[:skill_multiplier_default].to_s.strip
    if !sheet_ratio.empty? && sheet_ratio.match?(/\A-?\d+(\.\d+)?\z/)
      ctx[:creature_skill_ratio_override] = sheet_ratio.to_f
    end
    battle_actions = battle_actions.merge('__creature__' => { type: creature_skill_name, target: '__creature__' })
  end

  runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, creature[:pos])
  base_stats   = runner_sheet.read_base_stats
  # '__creature__'는 보스(크리쳐)가 러너와 동일한 지원/방어 스킬을 자기
  # 자신에게 사용할 때 쓰는 내부 전용 이름이다. stats_of/state_of가 이
  # 이름에 대해 크리쳐 객체를 반환하도록 해, 기존 러너 스킬 처리 루프를
  # 크리쳐도 그대로 통과할 수 있게 한다.
  stats_of = lambda do |name|
    return { house: '', passive: '', atk: creature[:atk].to_i, dur: creature[:dur].to_i,
             agi: creature[:agi].to_i, tec: creature[:tec].to_i, luck: creature[:luck].to_i,
             display_name: creature[:name].to_s } if name.to_s == '__creature__'
    base_stats.find { |s| s[:name].to_s.casecmp?(name.to_s) } || {}
  end
  state_of = lambda do |name|
    if name.to_s == '__creature__'
      # merge(사본)가 아니라 creature 원본을 그대로 반환해, t[:hp] = ... 같은
      # 직접 대입이 실제 크리쳐 HP에 반영되도록 한다.
      creature[:hp] = creature[:hp].to_i
      creature[:max_hp] = creature[:max_hp].to_i
      creature[:name_display_cache] ||= creature[:name].to_s
      next creature
    end
    runner_state.find { |r| r[:name].to_s == name.to_s }
  end

  # 스탯 시트의 캐릭터명과 준비 라운드에서 입력한 실제 위치를
  # 정산용 runner_state에 다시 적용합니다.
  saved_positions = ctx[:positions].is_a?(Hash) ? ctx[:positions] : {}

  runner_state.each do |runner|
    account_id = runner[:name].to_s
    stat = stats_of.call(account_id)

    display_name = stat[:display_name].to_s.strip
    runner[:display_name] = display_name.empty? ? account_id : display_name

    saved_pos = saved_positions[account_id]
    saved_pos = saved_positions[account_id.to_sym] if saved_pos.nil?
    saved_pos = saved_pos.to_s.strip.upcase

    runner[:pos] = saved_pos if saved_pos.match?(/\A[A-G][1-8]\z/)
  end

  display_name_of = lambda do |name|
    return creature[:name].to_s if name.to_s == '__creature__'
    runner = state_of.call(name)
    label = runner && runner[:display_name].to_s.strip
    label.nil? || label.empty? ? name.to_s : label
  end

  log = []
  took_damage = {}

  escaped_name = nil
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    next unless skill && BattleSkills.escape?(skill_name)

    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0

    dname = display_name_of.call(name)
    rate = (skill[:success_rate].to_f * 100).round
    roll = rand(1..100)
    success = roll <= rate

    if skill_name == '말걸기'
      if success
        line = TalkLines.success_line(creature[:name])
        log << "#{dname}의 말걸기 → #{creature[:name]}: \"#{line}\""
      else
        log << "#{dname}의 말걸기 → 말이 통하지 않는다!"
      end
    else
      log << "#{dname}의 #{skill_name} → #{success ? '성공! 전투에서 벗어났다.' : '실패. 벗어나지 못했다.'}"
    end

    if success
      escaped_name = name
      break
    end
  end

  if escaped_name
    ctx[:escaped_by] = escaped_name
    battle_actions.each { |name, act| ctx[:prev_action][name] = act[:type] }
    view_sheet.update_runner_state(runner_state)
    return [log, runner_state]
  end

  BattleBossPatterns.apply_ongoing_debuffs!(log, runner_state, ctx)
  rush_moves = prepare_rush_moves!(battle_actions, runner_state, creature, ctx, state_of)

  atk_bonus  = Hash.new(0)
  dur_bonus  = Hash.new(0)
  tec_bonus  = Hash.new(0)
  luck_bonus = Hash.new(0)
  agi_bonus  = Hash.new(0)
  defended_multiplier = Hash.new(1.0)

  # [시야차단]은 부여된 라운드 + 다음 라운드까지 적용(N+1)
  creature_atk_before_blind = nil
  shields = ctx[:shields]

  runner_names.each do |name|
    atk_bonus[name]  += stat_bonus(ctx, name, :atk)
    dur_bonus[name]  += stat_bonus(ctx, name, :dur)
    tec_bonus[name]  += stat_bonus(ctx, name, :tec)
    luck_bonus[name] += stat_bonus(ctx, name, :luck)
    agi_bonus[name]  += stat_bonus(ctx, name, :agi)
  end

  passive_lines = []
  runner_names.each do |name|
    s  = stats_of.call(name)
    st = state_of.call(name)
    next unless st && st[:hp].to_i > 0

    case s[:house].to_s.strip
    when '그리핀도르'
      if s[:passive] == '1' && creature && BattleCalculator.in_front?(creature[:pos], st[:pos], creature[:facing].to_s)
        b = (s[:dur].to_i * 0.5).ceil
        dur_bonus[name] += b
        passive_lines << "#{display_name_of.call(name)}: [그리핀도르] 적 정면 1칸 — 내구도 +#{b}"
      end
      if s[:passive] == '2' && st[:max_hp].to_i > 0 && st[:hp].to_f < st[:max_hp].to_i * 0.4
        b = (s[:atk].to_i * 0.5).ceil
        atk_bonus[name] += b
        passive_lines << "#{display_name_of.call(name)}: [그리핀도르] 건강 40% 미만 — 마법능력 +#{b}"
      end
    when '슬리데린'
      if s[:passive] == '1' && ctx[:round].to_i > 1 && !ctx[:prev_took_damage][name]
        b = (s[:atk].to_i * 0.5).ceil
        atk_bonus[name] += b
        passive_lines << "#{display_name_of.call(name)}: [슬리데린] 이전 라운드 무피해 — 마법능력 +#{b}"
      end
      if s[:passive] == '2' && ctx[:slytherin_luck][name].to_i > 0
        luck_bonus[name] += ctx[:slytherin_luck][name]
        passive_lines << "#{display_name_of.call(name)}: [슬리데린] 관찰 보너스 — 행운 +#{ctx[:slytherin_luck][name]}"
      end
    when '래번클로'
      creature_has_ailment = !ctx[:confusion_active].nil? || !ctx[:blind_active].nil?
      if s[:passive] == '1' && creature_has_ailment
        b = (s[:atk].to_i * 0.5).ceil
        atk_bonus[name] += b
        passive_lines << "#{display_name_of.call(name)}: [래번클로] 적 상태이상 감지 — 마법능력 +#{b}"
      elsif s[:passive] == '2'
        prev_cat = BattleSkills.category(ctx[:prev_action][name])
        cur_cat  = BattleSkills.category(battle_actions[name]&.dig(:type))
        if prev_cat && cur_cat && prev_cat != cur_cat
          tec_bonus[name] += 10
          passive_lines << "#{display_name_of.call(name)}: [래번클로] 행동 분류 변경 — 기술 +10"
        end
      end
    when '후플푸프'
      if s[:passive] == '1' && ctx[:prev_took_damage][name]
        b = (s[:dur].to_i * 0.5).ceil
        dur_bonus[name] += b
        passive_lines << "#{display_name_of.call(name)}: [후플푸프] 이전 라운드 피격 — 내구도 +#{b}"
      end
    end
  end

  if passive_lines.any?
    log << '[기숙사 패시브]'
    log.concat(passive_lines)
  end

  pending_absorb = nil
  ctx[:potion_used] = []

  # 1) 지원
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    if name.to_s == '__creature__' && skill && ctx[:creature_skill_ratio_override]
      skill = skill.merge(ratio: ctx[:creature_skill_ratio_override])
    end
    next unless skill && BattleSkills.support?(skill_name)

    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)
    parts = skill_parts(act[:target])
    target_names = split_targets(parts[0])
    target_name = target_names.first.to_s
    target = state_of.call(target_name)
    dname = display_name_of.call(name)

    if skill[:once]
      if !can_use_once?(ctx, name, skill_name)
        log << "#{dname}의 #{skill_name} → 이미 사용한 전투 중 1회 스킬"
        next
      end
      mark_once!(ctx, name, skill_name)
    end

    next unless cooldown_gate!(ctx, log, name, skill_name, skill, dname)

    case skill[:kind]
    when :heal
      healed = []
      target_names.each do |tname|
        t = state_of.call(tname)
        next unless t && t[:hp].to_i > 0
        heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
        before = t[:hp].to_i
        t[:hp] = [before + heal, t[:max_hp].to_i].min
        healed << "#{display_name_of.call(tname)} 건강 +#{t[:hp] - before}"
      end
      log << "#{dname}의 #{skill_name} → #{healed.join(', ')}" if healed.any?
    when :heal_fixed
      healed = []
      # 전투 중 물약은 대상 1명만 회복한다. 체력 0인 대상은 효과 없음, 소지품 차감 없음.
      target_names.first(1).each do |tname|
        t = state_of.call(tname)
        unless t && t[:hp].to_i > 0
          log << "#{dname}의 #{skill_name} → #{display_name_of.call(tname)}은(는) 행동불능이라 효과가 없습니다." if t
          next
        end
        before = t[:hp].to_i
        t[:hp] = [before + skill[:value].to_i, t[:max_hp].to_i].min
        healed << "#{display_name_of.call(tname)} 건강 +#{t[:hp] - before}"
        if BattleItems.potion?(skill_name)
          (ctx[:potion_used] ||= []) << { user: name, skill: skill_name }
        end
      end
      log << "#{dname}의 #{skill_name} → #{healed.join(', ')}" if healed.any?
    when :heal_fixed_self
      # 4) 보스 패턴 단계로 실행을 미룬다. 이번 라운드 방어/철벽 버프(2단계에서
      # 갱신됨)가 반영된 뒤에 피해를 계산하기 위함. 쿨타임/1회성 체크는
      # 여기서 이미 끝났으므로 값만 담아두고 실제 처리는 뒤에서 한다.
      pending_absorb = { name: name, skill: skill, skill_name: skill_name, s: s, actor: actor, dname: dname }
    when :heal_self_pure
      # 크리쳐 전용 순수 자가 회복(피흡 없음). 시전자의 마법능력 × 배율만큼
      # 그대로 자기 HP를 회복한다.
      t = actor
      if t && t[:hp].to_i > 0
        heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
        before = t[:hp].to_i
        t[:hp] = [before + heal, t[:max_hp].to_i].min
        log << "#{dname}의 #{skill_name} → #{dname} 건강 +#{t[:hp] - before}"
      end
    when :heal_area
      healed = []
      if name.to_s == '__creature__'
        heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
        before = actor[:hp].to_i
        actor[:hp] = [before + heal, actor[:max_hp].to_i].min
        healed << "#{dname} +#{actor[:hp] - before}"
      else
        runner_state.each do |r|
          next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
          next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
          heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
          before = r[:hp].to_i
          r[:hp] = [before + heal, r[:max_hp].to_i].min
          healed << "#{display_name_of.call(r[:name])} +#{r[:hp] - before}"
        end
      end
      log << "#{dname}의 #{skill_name} → #{healed.join(', ')}" if healed.any?
    when :atk_buff_area
      base_amount = s[:atk].to_i + atk_bonus[name]
      amount = (base_amount * skill[:ratio].to_f).ceil
      affected = []
      if name.to_s == '__creature__'
        existing = atk_bonus['__creature__'].to_i
        atk_bonus['__creature__'] = amount
        affected << dname
      else
        runner_state.each do |r|
          next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
          next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
          existing = stat_bonus(ctx, r[:name], :atk)
          ctx[:buffs][r[:name]].reject! { |b| b[:stat] == :atk }
          atk_bonus[r[:name]] += (amount - existing)
          ctx[:buffs][r[:name]] << { stat: :atk, value: amount, turns: 1 }
          affected << display_name_of.call(r[:name])
        end
      end
      log << "#{dname}의 강화 → #{affected.join(', ')} 마법능력 +#{amount}" if affected.any?
    when :shield
      applied = []
      limit = skill[:max_targets] || target_names.size
      target_names.first(limit).each do |tname|
        t = state_of.call(tname)
        next unless t
        shields[tname] += skill[:value].to_i
        applied << display_name_of.call(tname)
      end
      log << "#{dname}의 보호 → #{applied.join(', ')} 보호막 +#{skill[:value]}" if applied.any?
    when :sure_hit
      applied = []
      target_names.each do |tname|
        t = state_of.call(tname)
        next unless t
        ctx[:sure_hit][tname] = true
        applied << display_name_of.call(tname)
      end
      log << "#{dname}의 백발백중 → #{applied.join(', ')}의 다음 공격 필중/크리티컬" if applied.any?
    when :luck_buff
      applied = []
      target_names.each do |tname|
        t = state_of.call(tname)
        next unless t
        luck_bonus[tname] += skill[:value].to_i
        ctx[:buffs][tname] << { stat: :luck, value: skill[:value].to_i, turns: skill[:turns].to_i }
        applied << display_name_of.call(tname)
      end
      log << "#{dname}의 응원 → #{applied.join(', ')} 행운 +#{skill[:value]} (#{skill[:turns]}턴)" if applied.any?
    when :cooldown_reset
      skill_to_reset = parts[1].to_s.strip
      if skill_to_reset.empty?
        log << "#{dname}의 즉발 → 초기화할 스킬명 미입력 (무효)"
      else
        applied = []
        target_names.each do |tname|
          t = state_of.call(tname)
          next unless t
          ctx[:cooldowns][tname].delete(skill_to_reset)
          applied << display_name_of.call(tname)
        end
        if applied.any?
          log << "#{dname}의 즉발 → #{applied.join(', ')}의 [#{skill_to_reset}] 쿨타임 초기화"
        else
          log << "#{dname}의 즉발 → 대상 없음 (무효)"
        end
      end
    when :force_move
      coord = parts[1].to_s.upcase
      if target && BattleGrid.valid_pos?(coord)
        ok, msg = BattleGrid.movable?(target[:pos], coord, runner_state, creature, actor_name: target[:name])
        if ok
          target[:pos] = coord
          (ctx[:positions] ||= {})[target_name.to_s] = coord
          log << "#{dname}의 행운부여 → #{display_name_of.call(target_name)}을(를) #{coord}로 이동"
        else
          log << "#{dname}의 행운부여 실패 → #{msg}"
        end
      end
    end
  end

  # 2) 방어
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    if name.to_s == '__creature__' && skill && ctx[:creature_skill_ratio_override]
      skill = skill.merge(ratio: ctx[:creature_skill_ratio_override])
    end
    next unless skill && BattleSkills.defense?(skill_name)

    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)
    parts = skill_parts(act[:target])
    target_name = normalize_target(parts[0])
    target_name = name if target_name.empty? && skill[:range] == '자신'
    target = state_of.call(target_name)
    dname = display_name_of.call(name)

    if skill[:once]
      if !can_use_once?(ctx, name, skill_name)
        log << "#{dname}의 #{skill_name} → 이미 사용한 전투 중 1회 스킬"
        next
      end
      mark_once!(ctx, name, skill_name)
    end

    next unless cooldown_gate!(ctx, log, name, skill_name, skill, dname)

    case skill[:kind]
    when :dur_guard
      target_name = name if target_name.empty?
      defended_multiplier[target_name] *= skill[:ratio].to_f
      log << "#{dname}의 방어 → #{display_name_of.call(target_name)} 내구도 1.5배"
    when :agi_buff_self
      agi_bonus[name] += skill[:value].to_i
      log << "#{dname}의 회피 → 민첩 +#{skill[:value]}"
    when :revenge
      applied = []
      revenge_targets = split_targets(parts[0])
      revenge_targets = [target_name] if revenge_targets.empty?
      limit = skill[:max_targets] || revenge_targets.size
      revenge_targets.first(limit).each do |tname|
        t = state_of.call(tname)
        next unless t
        ctx[:revenge][tname] = { by: name, multiplier: skill[:multiplier] }
        applied << display_name_of.call(tname)
      end
      log << "#{dname}의 복수 → #{applied.join(', ')} 피격 시 반격 대기" if applied.any?
    when :cover
      ctx[:cover][target_name] = name if target
      log << "#{dname}의 희생 → #{display_name_of.call(target_name)} 대신 피격 대기" if target
    when :dur_buff_area
      # 강화(atk_buff_area)와 동일하게, 캐스터 자신에게 이미 누적된 내구도
      # 보너스(그리핀도르1 패시브 등)를 기준값에 포함해 계산한다.
      amount = ((s[:dur].to_i + dur_bonus[name].to_i) * skill[:ratio].to_f).ceil
      affected = []
      if name.to_s == '__creature__'
        dur_bonus['__creature__'] += amount
        affected << dname
      else
        runner_state.each do |r|
          next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
          next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
          dur_bonus[r[:name]] += amount
          affected << display_name_of.call(r[:name])
        end
      end
      log << "#{dname}의 철벽 → #{affected.join(', ')} 내구도 +#{amount}" if affected.any?
    when :agi_buff_area
      affected = []
      if name.to_s == '__creature__'
        agi_bonus['__creature__'] += skill[:value].to_i
        affected << dname
      else
        runner_state.each do |r|
          next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
          next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
          agi_bonus[r[:name]] += skill[:value].to_i
          affected << display_name_of.call(r[:name])
        end
      end
      log << "#{dname}의 주의분산 → #{affected.join(', ')} 민첩 +#{skill[:value]}" if affected.any?
    when :survive_once
      ctx[:survive_once][name] = true
      log << "#{dname}의 필사즉생 → 이번 턴 건강 0 이하 방지"
    end
  end

  # 3) 러너 공격
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    next unless skill && BattleSkills.attack?(skill_name)
    next if creature[:hp].to_i <= 0

    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)

    if skill[:once]
      if !can_use_once?(ctx, name, skill_name)
        log << "#{display_name_of.call(name)}의 #{skill_name} → 이미 사용한 전투 중 1회 스킬"
        next
      end
      mark_once!(ctx, name, skill_name)
    end

    next unless cooldown_gate!(ctx, log, name, skill_name, skill, display_name_of.call(name))

    sure = ctx[:sure_hit].delete(name)
    sacrifice_attack = skill[:kind] == :sacrifice_attack
    rush_attack = skill[:kind] == :rush

    eff_atk = s[:atk].to_i + atk_bonus[name]
    multiplier = skill[:multiplier] || 1.0

    # 습격은 "돌진해서 때리는" 행동이라, 공격 명중/회피 판정과 무관하게
    # 먼저 이동부터 처리합니다. 공격이 빗나가도 돌진 자체는 이미 일어난
    # 행동이므로 제자리로 남지 않습니다.
    if rush_attack
      info = rush_moves[name]
      if info
        multiplier = info[:multiplier]
        log << "#{display_name_of.call(name)}의 습격 이동 #{info[:old_pos]} → #{info[:dest]}" if info[:moved]
      end
    elsif skill[:kind] == :area_attack
      # 폭발 전용 기믹: 크리쳐가 여러 칸을 차지하는 경우, 폭발 범위 안에
      # 걸리는 칸 수만큼 배율을 곱한다. 다른 공격 스킬(공격/초인적인힘/
      # 혼란/고육지책 등)은 이 규칙 대상이 아니다 — 배율 1배 그대로 유지.
      hits = cells_hit_count(actor[:pos], skill[:range], creature)
      if hits > 1
        multiplier = (multiplier.to_f * hits)
        log << "#{display_name_of.call(name)}의 #{skill_name} → 크리쳐 점유칸 #{hits}칸 명중, 배율 ×#{hits}"
      end
    end

    hit_detail = nil
    evade_detail = nil
    crit_detail = nil

    log << "판정 결과"

    if sure || sacrifice_attack
      log << "명중: 자동 명중"
    else
      hit_detail = BattleCalculator.hit_detail(s[:tec].to_i + tec_bonus[name])
      log << "명중 #{hit_detail[:rate]}% → #{hit_detail[:roll]} (#{hit_detail[:success] ? '명중' : '빗나감'})"

      unless hit_detail[:success]
        log << "#{display_name_of.call(name)}의 #{skill_name} → 공격 실패"
        next
      end
    end

    unless sure || sacrifice_attack
      evade_detail = BattleCalculator.evade_detail(creature[:agi].to_i, base: creature[:evade_base].to_i)
      if evade_detail && evade_detail[:roll]
        log << "회피 #{evade_detail[:rate]}% → #{evade_detail[:roll]} (#{evade_detail[:success] ? '회피' : '피격'})"
      end

      if evade_detail && evade_detail[:success]
        log << "#{creature[:name]} 회피 — 피해 없음"
        next
      end
    end

    if sure
      crit = true
      log << "크리티컬: 자동 크리티컬"
    else
      crit_detail = BattleCalculator.critical_detail(s[:luck].to_i + luck_bonus[name])
      crit = crit_detail[:success]
      if crit_detail[:roll]
        log << "크리티컬 #{crit_detail[:rate]}% → #{crit_detail[:roll]} (#{crit ? '크리티컬' : '일반'})"
      else
        log << "크리티컬 #{crit_detail[:rate]}% → 판정 없음 (일반)"
      end
    end

    if sacrifice_attack
      parts = skill_parts(act[:target])
      cost = parts[1].to_i
      cost = 10 if cost <= 0
      cost = [cost, actor[:hp].to_i - 1].min

      before_hp = actor[:hp].to_i
      actor[:hp] -= cost

      bonus = (cost * 1.5).ceil
      eff_atk += bonus

      log << "#{display_name_of.call(name)}의 고육지책"
      log << "#{display_name_of.call(name)} 건강 #{before_hp} → #{actor[:hp]} (소모 #{cost})"
      log << "마법능력 +#{bonus}"
    end

    creature_eff_dur = (creature[:dur].to_i + dur_bonus['__creature__'].to_i) * defended_multiplier['__creature__'].to_f
    apply_damage_to_creature(
      log,
      creature,
      display_name_of.call(name),
      skill_name,
      eff_atk,
      multiplier,
      creature_eff_dur.to_i,
      crit: crit,
      guaranteed: sure
    )

    case skill[:kind]
    when :attack_debuff
      # [시야차단]은 부여 라운드+다음 라운드까지 유지, 이미 걸려있으면 중첩/갱신하지 않는다.
      if ctx[:blind_active].nil?
        creature_atk_before_blind = creature[:atk].to_i
        down = (creature_atk_before_blind * 0.2).ceil
        creature[:atk] = [creature_atk_before_blind - down, 0].max
        ctx[:blind_active] = { original_atk: creature_atk_before_blind, expires_round: ctx[:round].to_i + 1 }
        log << "#{creature[:name]} [시야차단] 마법능력 #{creature_atk_before_blind} → #{creature[:atk]} (이번 라운드+다음 라운드)"
      else
        log << "#{creature[:name]} [시야차단] 이미 적용 중 — 추가 감소 없음"
      end
    when :confusion
      immune = ctx[:confusion_immune_until].to_i >= ctx[:round].to_i
      if immune
        log << "#{creature[:name]}은(는) 혼란 면역 상태입니다. (#{ctx[:confusion_immune_until].to_i - ctx[:round].to_i + 1}라운드 남음)"
      else
        ctx[:confusion][creature[:name]] += 1
        log << "#{creature[:name]} 혼란 #{ctx[:confusion][creature[:name]]}/2중첩"
        if ctx[:confusion][creature[:name]] >= 2
          ctx[:confusion][creature[:name]] = 0
          ctx[:confusion_pending_invalidate] = true
          ctx[:confusion_active] = { expires_round: ctx[:round].to_i + 1 }
          ctx[:confusion_immune_until] = ctx[:round].to_i + 2
          log << "#{creature[:name]} 혼란 2중첩 도달 — 이번 라운드 행동 무효화 (이후 2턴 면역)"
        end
      end
    end
  end

  # 4) 보스 패턴/디버프
  # 혼란 2중첩 도달 시 그 라운드 보스 패턴/기본 반격 둘 다 스킵한다.
  # (기존에는 기본 반격 분기에서만 체크되어, 보스가 패턴 스킬을 쓰는
  # 라운드에는 중첩이 차도 무시되고 있었다.)
  confused_out = ctx.delete(:confusion_pending_invalidate) == true
  if confused_out
    log << "#{creature[:name]}은(는) 혼란으로 행동할 수 없습니다."
  end

  boss_skill_used = false
  if creature[:hp].to_i > 0 && !confused_out && !creature_uses_runner_skill
    boss_skill_used = BattleBossPatterns.apply_pattern!(
      log,
      runner_state,
      creature,
      ctx,
      stats_of: stats_of,
      dur_bonus: dur_bonus,
      defended_multiplier: defended_multiplier,
      shields: shields,
      took_damage: took_damage,
      agi_bonus: agi_bonus
    )
  end

  if pending_absorb && creature[:hp].to_i > 0 && !confused_out
    name       = pending_absorb[:name]
    skill      = pending_absorb[:skill]
    skill_name = pending_absorb[:skill_name]
    s          = pending_absorb[:s]
    actor      = pending_absorb[:actor]
    dname      = pending_absorb[:dname]

    # 크리쳐 전용 흡수. 살아있는 러너 중 무작위 1명을 대상으로 명중/회피
    # 판정을 거쳐 피해를 입히고(방어/보호막 반영), 실제로 들어간 피해량만큼
    # 시전자(크리쳐) 자신의 HP를 그대로 회복한다(1:1 흡수).
    absorb_targets = runner_state.select { |r| r[:hp].to_i > 0 && runner_names.include?(r[:name]) }
    if absorb_targets.any?
      absorb_target = absorb_targets.sample
      aname = absorb_target[:name]
      ats = stats_of.call(aname)
      adname = display_name_of.call(aname)

      hit_detail = BattleCalculator.hit_detail(s[:tec].to_i + tec_bonus[name])
      log << "#{dname}의 #{skill_name} → #{adname} 명중 #{hit_detail[:rate]}% → #{hit_detail[:roll]} (#{hit_detail[:success] ? '명중' : '빗나감'})"

      if hit_detail[:success]
        evade_detail = BattleCalculator.evade_detail(ats[:agi].to_i + agi_bonus[aname])
        if evade_detail[:roll]
          log << "#{adname} 회피 #{evade_detail[:rate]}% → #{evade_detail[:roll]} (#{evade_detail[:success] ? '회피' : '피격'})"
        end

        if evade_detail[:success]
          log << "#{adname} 회피 — 흡수 실패"
        else
          base_power = (s[:atk].to_i * skill[:ratio].to_f).ceil
          eff_dur = (ats[:dur].to_i + dur_bonus[aname]) * defended_multiplier[aname]
          dmg = BattleCalculator.calc_damage(base_power, eff_dur.to_i)

          if shields[aname].to_i > 0 && dmg > 0
            blocked = [shields[aname], dmg].min
            shields[aname] -= blocked
            dmg -= blocked
            log << "#{adname} 보호막 #{blocked} 흡수(차단)"
          end

          absorb_target[:hp] = [absorb_target[:hp].to_i - dmg, 0].max
          took_damage[aname] = true if dmg > 0

          before = actor[:hp].to_i
          actor[:hp] = [before + dmg, actor[:max_hp].to_i].min
          log << "#{dname}의 #{skill_name} → #{adname}에게 #{dmg} 피해, #{dname} 건강 +#{actor[:hp] - before}"

          if absorb_target[:hp] <= 0
            absorb_target[:status] = '전투불가'
            log << "#{adname} 전투불가"
          end
        end
      else
        log << "#{dname}의 #{skill_name} → 흡수 실패"
      end
    else
      log << "#{dname}의 #{skill_name} → 대상 없음 (무효)"
    end
  end

  # 5) 크리쳐 반격 — 제거됨 (요청에 따라 기본 반격 기능 완전 삭제)
  # 참고: '복수' 반사 로직은 battle_boss_patterns.rb(보스패턴 공격)에
  # 별도로 존재하므로, 이 기본 반격 제거는 복수 스킬 자체를 무력화하지 않음.

  runner_names.each do |name|
    s = stats_of.call(name)
    if s[:house].to_s.strip == '슬리데린' && s[:passive] == '2' &&
       (battle_actions[name].nil? || battle_actions[name][:type] == '관찰')
      st = state_of.call(name)
      if st && st[:hp].to_i > 0
        ctx[:slytherin_luck][name] += 10
        log << "#{display_name_of.call(name)}: [슬리데린] 행동을 포기하고 상황을 살핍니다. (다음 라운드부터 행운 +10)"
      end
    end
  end

  ctx[:indomitable_buffer].to_a.each do |name, total_power|
    next if total_power.to_i <= 0
    guardian = state_of.call(name)
    next unless guardian && guardian[:hp].to_i > 0
    gs = stats_of.call(name)
    eff_dur = (gs[:dur].to_i + dur_bonus[name]) * defended_multiplier[name]
    dmg = BattleCalculator.calc_damage(total_power.to_i, eff_dur.to_i)
    if shields[name].to_i > 0 && dmg > 0
      blocked = [shields[name], dmg].min
      shields[name] -= blocked
      dmg -= blocked
      log << "#{display_name_of.call(name)} 보호막 #{blocked} 흡수"
    end
    if guardian[:hp].to_i - dmg <= 0 && dmg > 0
      dmg = guardian[:hp].to_i - 1
      if gs[:house].to_s.strip == '후플푸프' && gs[:passive].to_s == '2' && !ctx[:guard_used][name]
        # 후플푸프 패시브2 보유자는 이 상황을 패시브 사용(전투 중 1회)으로 간주해
        # 다음 라운드 행동불가 페널티를 받지 않는다.
        ctx[:guard_used][name] = true
        log << "#{display_name_of.call(name)}: 필사즉생 → 이번 라운드 흡수한 총 위력 #{total_power}, 최종 피해 #{dmg} (건강 0 이하 방지 — [후플푸프] 패시브로 페널티 면제)"
      else
        ctx[:action_locked] ||= {}
        ctx[:action_locked][name] = true
        log << "#{display_name_of.call(name)}: 필사즉생 → 이번 라운드 흡수한 총 위력 #{total_power}, 최종 피해 #{dmg} (건강 0 이하 방지, 다음 라운드 행동 불가)"
      end
    else
      log << "#{display_name_of.call(name)}: 필사즉생 → 이번 라운드 흡수한 총 위력 #{total_power}, 최종 피해 #{dmg}"
    end
    guardian[:hp] = [guardian[:hp].to_i - dmg, 0].max
    took_damage[name] = true if dmg > 0
    if ctx[:revenge][name] && dmg > 0
      rev_by = ctx[:revenge][name][:by]
      rev_actor = state_of.call(rev_by)
      if rev_actor && rev_actor[:hp].to_i > 0
        creature_eff_dur_rev2 = (creature[:dur].to_i + dur_bonus['__creature__'].to_i) * defended_multiplier['__creature__'].to_f
        rev_dmg = BattleCalculator.calc_damage((dmg * ctx[:revenge][name][:multiplier]).ceil, creature_eff_dur_rev2.to_i)
        creature[:hp] = [creature[:hp].to_i - rev_dmg, 0].max
        log << "#{display_name_of.call(rev_by)}의 복수 → #{creature[:name]}에게 #{rev_dmg} 반격 피해"
      end
    end
    if guardian[:hp].to_i <= 0
      guardian[:status] = '전투불가'
      log << "#{display_name_of.call(name)} 전투불가"
    end
  end

  # [시야차단] 종료: 부여 라운드+다음 라운드가 지나야 원래 마법능력으로 복귀
  if ctx[:blind_active] && ctx[:round].to_i >= ctx[:blind_active][:expires_round].to_i
    creature[:atk] = ctx[:blind_active][:original_atk]
    ctx[:blind_active] = nil
  end

  # 혼란 "상태이상 있음" 표시(래번클로1 연동용)는 무효화 발동 라운드+
  # 다음 라운드까지만 유지하고, 그 이후 자동 소멸한다. 실제 행동봉쇄와는
  # 무관하며 오직 패시브 판정용 표시일 뿐이다.
  if ctx[:confusion_active] && ctx[:round].to_i >= ctx[:confusion_active][:expires_round].to_i
    ctx[:confusion_active] = nil
  end

  ctx[:prev_took_damage] = took_damage
  battle_actions.each { |name, act| ctx[:prev_action][name] = act[:type] }
  cleanup_buffs!(ctx)
  advance_cooldowns!(ctx)
  ctx[:cover] = {}
  ctx[:revenge] = {}
  ctx[:sure_hit] = {}
  ctx[:survive_once] = {}
  ctx[:indomitable_buffer] = Hash.new(0)

  view_sheet.update_runner_state(runner_state)
  [log, runner_state]
end

def action_text_for_result(name, action, creature_name)
  return "#{name}: 턴 상실" unless action

  type = action[:type].to_s
  target = action[:target].to_s

  if type == '순간이동'
    from = action[:from].to_s
    to = action[:to].to_s.empty? ? target : action[:to].to_s
    return "#{name}: 순간이동 #{from} → #{to}" unless from.empty?
    return "#{name}: 순간이동 #{to}"
  end

  return "#{name}: 필사즉생 후유증 (행동 불가)" if type == '필사즉생 후유증'

  target = creature_name if ['크리쳐', creature_name].include?(target)
  "#{name}: #{type} (#{target})"
end

def build_result_text(runner_tags, battle_round, creature, battle_actions, runner_names, log, runner_state, view_sheet, timeout: false)
  creature_name   = creature[:name].to_s.strip.empty? ? '크리쳐' : creature[:name].to_s.strip
  creature_hp     = creature[:hp].to_i
  creature_max_hp = (creature[:max_hp] || creature_hp).to_i

  title = timeout ? "[#{battle_round}라운드] #{creature_name} 전투 결과 (시간 초과)" : "[#{battle_round}라운드] #{creature_name} 전투 결과"

  base_stats = view_sheet.read_base_stats rescue []

  runner_state.each do |r|
    stat = base_stats.find { |s| s[:id].to_s.casecmp?(r[:name].to_s) }
    next unless stat

    label = stat[:display_name].to_s.strip
    r[:display_name] = label unless label.empty?
  end


  begin
    puts "[DEBUG] base_stats=#{base_stats.size}"

    runner_names.each do |id|
      row = base_stats.find { |s|
        s[:id].to_s == id.to_s ||
        s[:name].to_s == id.to_s
      }

      puts "[DEBUG] #{id} => #{row.inspect}"
    end
  rescue => e
    puts "[DEBUG] base_stats 확인 오류 #{e.class}: #{e.message}"
  end


  # 1툿: 행동 + 전장
  part1 = "#{runner_tags}

#{title}

"
  part1 += "────────────────────
"
  part1 += "행동
"

  runner_names.each do |name|
    runner = runner_state.find { |r| r[:name].to_s == name.to_s }
    label = runner && runner[:display_name].to_s.strip
    label = name if label.nil? || label.empty?

    part1 += "#{action_text_for_result(label, battle_actions[name], creature_name)}
"
  end

  moved = battle_actions.select { |_name, act| act && act[:type].to_s == '순간이동' && !act[:from].to_s.empty? }
  if moved.any?
    part1 += "
순간이동
"
    moved.each do |name, act|
      runner = runner_state.find { |r| r[:name].to_s == name.to_s }
      label = runner && runner[:display_name].to_s.strip
      label = name if label.nil? || label.empty?
      part1 += "#{label}: #{act[:from]} → #{act[:to]}
"
    end
  end

  part1 += "────────────────────
"
  part1 += "전장

"
  BattleGrid.render(runner_state, creature).each { |line| part1 += "#{line}
" }

  # 2툿: 전투 로그 + 상태
  # DM(direct) 발송 시 수신자 멘션이 없으면 게시는 되어도 상대방에게는
  # 보이지 않으므로, part1과 동일하게 runner_tags를 앞에 붙입니다.
  part2 = "#{runner_tags}

#{title} - 결과

"
  part2 += "전투 로그
"

  log.each do |line|
    pretty = line.to_s
    if pretty.include?('→')
      part2 += "▶ #{pretty}
"
    else
      part2 += "#{pretty}
"
    end
  end

  part2 += "────────────────────
"
  part2 += "상태
"

  runner_state.select { |r| runner_names.include?(r[:name]) }.each do |r|
    status_text = r[:status].to_s.strip
    status_text = " / #{status_text}" unless status_text.empty?
    part2 += "#{r[:display_name].to_s.empty? ? r[:name] : r[:display_name]}
"
    part2 += "#{view_sheet.health_bar(r[:hp], r[:max_hp])} / 위치 #{r[:pos]}#{status_text}

"
  end

  part2 += "#{creature_name}
"
  part2 += "#{view_sheet.health_bar(creature_hp, creature_max_hp)} (방향: #{creature[:facing] || '하'})
"
  part2 += "점유칸: #{BattleGrid.occupied_cells_label(creature)}
"
  part2 += "
"

  if creature_hp <= 0
    part2 += "#{creature_name} 격파! 전투 승리!"
  elsif runner_state.none? { |r| runner_names.include?(r[:name]) && r[:hp].to_i > 0 }
    part2 += "전원 전투 불능. 전투 패배."
  else
    part2 += "#{ROUND_WAIT_SECONDS}초 후 다음 라운드가 시작됩니다."
  end

  [part1, part2]
end
