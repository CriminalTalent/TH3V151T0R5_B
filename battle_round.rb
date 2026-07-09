# battle_round.rb
# encoding: UTF-8

# 전투 정산 순서:
# 지원 → 방어 → 공격 → 크리쳐 반격

def stat_bonus(ctx, name, stat)
  ctx[:buffs][name].to_a.select { |b| b[:stat] == stat }.sum { |b| b[:value].to_i }
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
def cooldown_gate!(ctx, log, name, skill_name, skill)
  return true if skill[:once]
  cd = skill[:cooldown].to_i
  return true if cd <= 0

  left = ctx[:cooldowns][name][skill_name].to_i
  if left > 0
    log << "#{name}의 #{skill_name} → 쿨타임 #{left}라운드 남음 (행동 무효)"
    return false
  end

  ctx[:cooldowns][name][skill_name] = cd
  true
end

def apply_damage_to_creature(log, creature, attacker_name, skill_name, atk_value, multiplier, dur, crit: false, guaranteed: false)
  base = (atk_value.to_f * multiplier.to_f).ceil
  base *= 2 if crit
  dmg = BattleCalculator.calc_damage(base, dur.to_i)
  creature[:hp] = [creature[:hp].to_i - dmg, 0].max
  flags = []
  flags << '필중' if guaranteed
  flags << '크리티컬' if crit
  suffix = flags.empty? ? '' : " (#{flags.join(', ')})"
  log << "#{attacker_name}의 #{skill_name} → #{creature[:name]}에게 #{dmg} 피해#{suffix}"
  dmg
end

def settle_round(battle_actions, runner_names, runner_sheet, creature_sheet, view_sheet, creature, ctx)
  runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, creature[:pos])
  base_stats   = runner_sheet.read_base_stats
  stats_of = ->(name) { base_stats.find { |s| s[:name] == name } || {} }
  state_of = ->(name) { runner_state.find { |r| r[:name] == name } }

  log = []
  took_damage = {}

  BattleBossPatterns.apply_ongoing_debuffs!(log, runner_state, ctx)

  atk_bonus  = Hash.new(0)
  dur_bonus  = Hash.new(0)
  tec_bonus  = Hash.new(0)
  luck_bonus = Hash.new(0)
  agi_bonus  = Hash.new(0)
  defended_multiplier = Hash.new(1.0)
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
      if s[:passive] == '2' && st[:max_hp].to_i > 0 && st[:hp].to_f < st[:max_hp].to_i * 0.5
        b = (s[:atk].to_i * 0.5).ceil
        atk_bonus[name] += b
        passive_lines << "#{name}: [그리핀도르] 건강 50% 미만 — 마법능력 +#{b}"
      end
    when '슬리데린'
      if s[:passive] == '1' && ctx[:round].to_i > 1 && !ctx[:prev_took_damage][name]
        b = (s[:atk].to_i * 0.5).ceil
        atk_bonus[name] += b
        passive_lines << "#{name}: [슬리데린] 이전 라운드 무피해 — 마법능력 +#{b}"
      end
      if s[:passive] == '2' && ctx[:slytherin_luck][name].to_i > 0
        luck_bonus[name] += ctx[:slytherin_luck][name]
        passive_lines << "#{name}: [슬리데린] 관찰 보너스 — 행운 +#{ctx[:slytherin_luck][name]}"
      end
    when '래번클로'
      if s[:passive] == '1' && !creature[:status].to_s.strip.empty?
        b = (s[:atk].to_i * 0.5).ceil
        atk_bonus[name] += b
        passive_lines << "#{name}: [래번클로] 적 상태이상 감지 — 마법능력 +#{b}"
      elsif s[:passive] == '2'
        prev = ctx[:prev_action][name]
        cur  = battle_actions[name]&.dig(:type)
        if prev && cur && prev != cur
          tec_bonus[name] += 10
          passive_lines << "#{name}: [래번클로] 행동 분류 변경 — 기술 +10"
        end
      end
    when '후플푸프'
      if s[:passive] == '1' && ctx[:prev_took_damage][name]
        b = (s[:dur].to_i * 0.5).ceil
        dur_bonus[name] += b
        passive_lines << "#{name}: [후플푸프] 이전 라운드 피격 — 내구도 +#{b}"
      end
    end
  end

  if passive_lines.any?
    log << '[기숙사 패시브]'
    log.concat(passive_lines)
  end

  # 1) 지원
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    next unless skill && BattleSkills.support?(skill_name)

    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)
    parts = skill_parts(act[:target])
    target_names = split_targets(parts[0])
    target_name = target_names.first.to_s
    target = state_of.call(target_name)

    if skill[:once]
      if !can_use_once?(ctx, name, skill_name)
        log << "#{name}의 #{skill_name} → 이미 사용한 전투 중 1회 스킬"
        next
      end
      mark_once!(ctx, name, skill_name)
    end

    next unless cooldown_gate!(ctx, log, name, skill_name, skill)

    case skill[:kind]
    when :heal
      healed = []
      target_names.each do |tname|
        t = state_of.call(tname)
        next unless t && t[:hp].to_i > 0
        heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
        before = t[:hp].to_i
        t[:hp] = [before + heal, t[:max_hp].to_i].min
        healed << "#{tname} 건강 +#{t[:hp] - before}"
      end
      log << "#{name}의 #{skill_name} → #{healed.join(', ')}" if healed.any?
    when :heal_area
      healed = []
      runner_state.each do |r|
        next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
        next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
        heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
        before = r[:hp].to_i
        r[:hp] = [before + heal, r[:max_hp].to_i].min
        healed << "#{r[:name]} +#{r[:hp] - before}"
      end
      log << "#{name}의 #{skill_name} → #{healed.join(', ')}" if healed.any?
    when :atk_buff_area
      amount = (s[:atk].to_i * skill[:ratio].to_f).ceil
      affected = []
      runner_state.each do |r|
        next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
        next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
        atk_bonus[r[:name]] += amount
        ctx[:buffs][r[:name]] << { stat: :atk, value: amount, turns: 1 }
        affected << r[:name]
      end
      log << "#{name}의 강화 → #{affected.join(', ')} 마법능력 +#{amount}" if affected.any?
    when :shield
      applied = []
      limit = skill[:max_targets] || target_names.size
      target_names.first(limit).each do |tname|
        t = state_of.call(tname)
        next unless t
        shields[tname] += skill[:value].to_i
        applied << tname
      end
      log << "#{name}의 보호 → #{applied.join(', ')} 보호막 +#{skill[:value]}" if applied.any?
    when :sure_hit
      applied = []
      target_names.each do |tname|
        t = state_of.call(tname)
        next unless t
        ctx[:sure_hit][tname] = true
        applied << tname
      end
      log << "#{name}의 백발백중 → #{applied.join(', ')}의 다음 공격 필중/크리티컬" if applied.any?
    when :luck_buff
      applied = []
      target_names.each do |tname|
        t = state_of.call(tname)
        next unless t
        luck_bonus[tname] += skill[:value].to_i
        ctx[:buffs][tname] << { stat: :luck, value: skill[:value].to_i, turns: skill[:turns].to_i }
        applied << tname
      end
      log << "#{name}의 응원 → #{applied.join(', ')} 행운 +#{skill[:value]} (#{skill[:turns]}턴)" if applied.any?
    when :cooldown_reset
      skill_to_reset = parts[1].to_s.strip
      if skill_to_reset.empty?
        log << "#{name}의 즉발 → 초기화할 스킬명 미입력 (무효)"
      else
        applied = []
        target_names.each do |tname|
          t = state_of.call(tname)
          next unless t
          ctx[:cooldowns][tname].delete(skill_to_reset)
          applied << tname
        end
        if applied.any?
          log << "#{name}의 즉발 → #{applied.join(', ')}의 [#{skill_to_reset}] 쿨타임 초기화"
        else
          log << "#{name}의 즉발 → 대상 없음 (무효)"
        end
      end
    when :force_move
      coord = parts[1].to_s.upcase
      if target && BattleGrid.valid_pos?(coord)
        ok, msg = BattleGrid.movable?(target[:pos], coord, runner_state, creature, actor_name: target[:name])
        if ok
          target[:pos] = coord
          log << "#{name}의 행운부여 → #{target_name}을(를) #{coord}로 이동"
        else
          log << "#{name}의 행운부여 실패 → #{msg}"
        end
      end
    end
  end

  # 2) 방어
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    next unless skill && BattleSkills.defense?(skill_name)

    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)
    parts = skill_parts(act[:target])
    target_name = normalize_target(parts[0])
    target_name = name if target_name.empty? && skill[:range] == '자신'
    target = state_of.call(target_name)

    if skill[:once]
      if !can_use_once?(ctx, name, skill_name)
        log << "#{name}의 #{skill_name} → 이미 사용한 전투 중 1회 스킬"
        next
      end
      mark_once!(ctx, name, skill_name)
    end

    next unless cooldown_gate!(ctx, log, name, skill_name, skill)

    case skill[:kind]
    when :dur_guard
      target_name = name if target_name.empty?
      dur_bonus[target_name] += (stats_of.call(target_name)[:dur].to_i * 0.5).ceil
      defended_multiplier[target_name] *= skill[:ratio].to_f
      log << "#{name}의 방어 → #{target_name} 내구도 1.5배"
    when :agi_buff_self
      agi_bonus[name] += skill[:value].to_i
      log << "#{name}의 회피 → 민첩 +#{skill[:value]}"
    when :revenge
      ctx[:revenge][target_name] = { by: name, multiplier: skill[:multiplier] }
      log << "#{name}의 복수 → #{target_name} 피격 시 반격 대기"
    when :cover
      ctx[:cover][target_name] = name if target
      log << "#{name}의 희생 → #{target_name} 대신 피격 대기" if target
    when :dur_buff_area
      amount = (s[:dur].to_i * skill[:ratio].to_f).ceil
      affected = []
      runner_state.each do |r|
        next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
        next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
        dur_bonus[r[:name]] += amount
        affected << r[:name]
      end
      log << "#{name}의 철벽 → #{affected.join(', ')} 내구도 +#{amount}" if affected.any?
    when :agi_buff_area
      affected = []
      runner_state.each do |r|
        next unless r[:hp].to_i > 0 && runner_names.include?(r[:name])
        next unless BattleGrid.in_range?(actor[:pos], r[:pos], skill[:range])
        agi_bonus[r[:name]] += skill[:value].to_i
        affected << r[:name]
      end
      log << "#{name}의 주의분산 → #{affected.join(', ')} 민첩 +#{skill[:value]}" if affected.any?
    when :survive_once
      ctx[:survive_once][name] = true
      log << "#{name}의 필사즉생 → 이번 턴 건강 0 이하 방지"
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
        log << "#{name}의 #{skill_name} → 이미 사용한 전투 중 1회 스킬"
        next
      end
      mark_once!(ctx, name, skill_name)
    end

    next unless cooldown_gate!(ctx, log, name, skill_name, skill)

    sure = ctx[:sure_hit].delete(name)
    hit_detail = BattleCalculator.hit_detail(s[:tec].to_i + tec_bonus[name])
    hit_ok = sure || skill[:kind] == :sacrifice_attack || hit_detail[:success]
    unless hit_ok
      log << "#{name}의 #{skill_name} → 빗나감!"
      next
    end

    unless sure || skill[:kind] == :sacrifice_attack
      if BattleCalculator.evade?(creature[:agi].to_i)
        log << "#{name}의 #{skill_name} → #{creature[:name]} 회피!"
        next
      end
    end

    crit_detail = BattleCalculator.critical_detail(s[:luck].to_i + luck_bonus[name])
    crit = sure || crit_detail[:success]

    unless sure || skill[:kind] == :sacrifice_attack
      log << "판정 결과"
      log << "명중 #{hit_detail[:rate]}% → #{hit_detail[:roll]} (#{hit_detail[:success] ? '명중' : '실패'})"
      log << "크리티컬 #{crit_detail[:rate]}% → #{crit_detail[:roll]} (#{crit_detail[:success] ? '크리티컬' : '일반'})"
      log << ""
    end
    eff_atk = s[:atk].to_i + atk_bonus[name]
    multiplier = skill[:multiplier] || 1.0

    if skill[:kind] == :sacrifice_attack
      parts = skill_parts(act[:target])
      cost = parts[1].to_i
      cost = 10 if cost <= 0
      cost = [cost, actor[:hp].to_i - 1].min
      actor[:hp] -= cost
      eff_atk += (cost / 10) * 5
      log << "#{name}의 고육지책 → 건강 #{cost} 소모, 마법능력 +#{(cost / 10) * 5}"
    elsif skill[:kind] == :rush
      parts = skill_parts(act[:target])
      dest = parts[1].to_s.upcase
      if BattleGrid.valid_pos?(dest)
        dist = BattleGrid.distance(actor[:pos], dest).to_i
        multiplier = dist >= 5 ? skill[:long_multiplier] : skill[:multiplier]
        actor[:pos] = dest if BattleGrid.line_clear?(actor[:pos], dest, runner_state, creature, actor_name: name)
      end
    end

    apply_damage_to_creature(log, creature, name, skill_name, eff_atk, multiplier, creature[:dur].to_i, crit: crit, guaranteed: sure)

    case skill[:kind]
    when :attack_debuff
      down = (creature[:atk].to_i * 0.2).ceil
      creature[:atk] = [creature[:atk].to_i - down, 0].max
      log << "#{creature[:name]}의 마법능력 -#{down}"
    when :confusion
      ctx[:confusion][creature[:name]] += 1
      log << "#{creature[:name]} 혼란 #{ctx[:confusion][creature[:name]]}/5중첩"
    end
  end

  # 4) 보스 패턴/디버프
  boss_skill_used = false
  if creature[:hp].to_i > 0
    boss_skill_used = BattleBossPatterns.apply_pattern!(
      log,
      runner_state,
      creature,
      ctx,
      stats_of: stats_of,
      dur_bonus: dur_bonus,
      defended_multiplier: defended_multiplier,
      shields: shields,
      took_damage: took_damage
    )
  end

  # 5) 크리쳐 반격
  # 현재스킬/이번턴스킬이 지정된 턴에는 그 스킬이 보스 행동이므로 기본 반격은 생략합니다.
  if creature[:hp].to_i > 0 && !boss_skill_used
    if ctx[:confusion][creature[:name]] >= 5
      log << "#{creature[:name]}은(는) 혼란 5중첩으로 행동할 수 없습니다."
      ctx[:confusion][creature[:name]] = 0
    else
      living = runner_state.select { |r| r[:hp].to_i > 0 && runner_names.include?(r[:name]) }
      if living.any?
        target = living.sample
        original_target = target
        cover_name = ctx[:cover][target[:name]]
        cover = state_of.call(cover_name) if cover_name
        target = cover if cover && cover[:hp].to_i > 0
        tname = target[:name]
        ts = stats_of.call(tname)

        unless BattleCalculator.hit?(creature[:tec].to_i)
          log << "#{creature[:name]}의 반격 → 빗나감!"
        else
          if BattleCalculator.evade?(ts[:agi].to_i + agi_bonus[tname])
            log << "#{creature[:name]}의 반격 → #{tname} 회피!"
          else
            crit = BattleCalculator.critical?(creature[:luck].to_i)
            base = crit ? creature[:atk].to_i * 2 : creature[:atk].to_i
            eff_dur = (ts[:dur].to_i + dur_bonus[tname]) * defended_multiplier[tname]

            if ts[:house].to_s.strip == '그리핀도르' && ts[:passive] == '1' &&
               BattleCalculator.in_front?(target[:pos], creature[:pos], ts[:facing].to_s)
              eff_dur = (eff_dur * 1.5).ceil
              log << "#{tname}: [그리핀도르] 공격자가 정면에 위치 — 내구도 1.5배"
            end

            dmg = BattleCalculator.calc_damage(base, eff_dur.to_i)

            if shields[tname].to_i > 0 && dmg > 0
              blocked = [shields[tname], dmg].min
              shields[tname] -= blocked
              dmg -= blocked
              log << "#{tname} 보호막 #{blocked} 흡수"
            end

            if ctx[:survive_once][tname] && target[:hp].to_i - dmg <= 0 && dmg > 0
              dmg = target[:hp].to_i - 1
              ctx[:survive_once].delete(tname)
              log << "#{tname}: 필사즉생으로 건강 0 이하 방지"
            elsif ts[:house].to_s.strip == '후플푸프' && ts[:passive] == '2' &&
                  !ctx[:guard_used][tname] && target[:hp].to_i - dmg <= 0 && dmg > 0
              dmg = target[:hp].to_i - 1
              ctx[:guard_used][tname] = true
              log << "#{tname}: [후플푸프] 전투 중 1회 — 건강 0 이하 방지"
            end

            target[:hp] = [target[:hp].to_i - dmg, 0].max
            took_damage[tname] = true if dmg > 0
            line = "#{creature[:name]}의 반격 → #{tname}에게 #{dmg} 피해#{crit ? ' (크리티컬!)' : ''}"
            line += " (#{original_target[:name]} 대신 피격)" if original_target != target
            log << line

            if ctx[:revenge][tname] && dmg > 0
              rev_by = ctx[:revenge][tname][:by]
              rev_actor = state_of.call(rev_by)
              rev_stats = stats_of.call(rev_by)
              if rev_actor && rev_actor[:hp].to_i > 0
                rev_dmg = BattleCalculator.calc_damage((dmg * ctx[:revenge][tname][:multiplier]).ceil, creature[:dur].to_i)
                creature[:hp] = [creature[:hp].to_i - rev_dmg, 0].max
                log << "#{rev_by}의 복수 → #{creature[:name]}에게 #{rev_dmg} 반격 피해"
              end
            end

            if target[:hp] <= 0
              target[:status] = '사망'
              log << "#{tname} 쓰러짐..."
            end
          end
        end
      end
    end
  end

  runner_names.each do |name|
    s = stats_of.call(name)
    if s[:house].to_s.strip == '슬리데린' && s[:passive] == '2' && battle_actions[name].nil?
      st = state_of.call(name)
      if st && st[:hp].to_i > 0
        ctx[:slytherin_luck][name] += 10
        log << "#{name}: [슬리데린] 행동을 포기하고 상황을 살핍니다. (다음 라운드부터 행운 +10)"
      end
    end
  end

  ctx[:prev_took_damage] = took_damage
  battle_actions.each { |name, act| ctx[:prev_action][name] = act[:type] }
  cleanup_buffs!(ctx)
  advance_cooldowns!(ctx)
  ctx[:cover] = {}
  ctx[:revenge] = {}
  ctx[:sure_hit] = {}
  ctx[:survive_once] = {}

  view_sheet.update_runner_state(runner_state)
  [log, runner_state]
end

def action_text_for_result(name, action, creature_name)
  return "#{name}: 턴 상실" unless action

  type = action[:type].to_s
  target = action[:target].to_s

  if type == '이동'
    from = action[:from].to_s
    to = action[:to].to_s.empty? ? target : action[:to].to_s
    return "#{name}: 이동 #{from} → #{to}" unless from.empty?
    return "#{name}: 이동 #{to}"
  end

  target = creature_name if ['크리쳐', creature_name].include?(target)
  "#{name}: #{type} (#{target})"
end

def build_result_text(runner_tags, battle_round, creature, battle_actions, runner_names, log, runner_state, view_sheet, timeout: false)
  creature_name   = creature[:name].to_s.strip.empty? ? '크리쳐' : creature[:name].to_s.strip
  creature_hp     = creature[:hp].to_i
  creature_max_hp = (creature[:max_hp] || creature_hp).to_i

  title = timeout ? "[#{battle_round}라운드] #{creature_name} 전투 결과 (시간 초과)" : "[#{battle_round}라운드] #{creature_name} 전투 결과"

  result = "#{runner_tags}\n\n#{title}\n\n"
  result += "────────────────────\n"
  result += "행동\n"
  runner_names.each do |name|
    result += "#{action_text_for_result(name, battle_actions[name], creature_name)}\n"
  end

  moved = battle_actions.select { |_name, act| act && act[:type].to_s == '이동' && !act[:from].to_s.empty? }
  if moved.any?
    result += "\n이동\n"
    moved.each do |name, act|
      result += "#{name}: #{act[:from]} → #{act[:to]}\n"
    end
  end

  result += "────────────────────\n"
  result += "전장\n\n"
  BattleGrid.render(runner_state, creature).each { |line| result += "#{line}\n" }

  result += "────────────────────\n"
  result += "전투 로그\n"
  log.each do |line|
    pretty = line.to_s
    if pretty.include?('→')
      result += "▶ #{pretty}\n"
    else
      result += "#{pretty}\n"
    end
  end

  result += "────────────────────\n"
  result += "상태\n"
  runner_state.select { |r| runner_names.include?(r[:name]) }.each do |r|
    status_text = r[:status].to_s.strip
    status_text = " / #{status_text}" unless status_text.empty?
    result += "#{r[:name]}\n"
    result += "#{view_sheet.health_bar(r[:hp], r[:max_hp])} / 위치 #{r[:pos]}#{status_text}\n\n"
  end

  result += "#{creature_name}\n"
  result += "#{view_sheet.health_bar(creature_hp, creature_max_hp)}\n"
  result += "점유칸: #{BattleGrid.creature_cells(creature).join(' · ')}\n"
  result += "\n"

  if creature_hp <= 0
    result += "#{creature_name} 격파! 전투 승리!"
  elsif runner_state.none? { |r| runner_names.include?(r[:name]) && r[:hp].to_i > 0 }
    result += "전원 전투 불능. 전투 패배."
  else
    result += "#{ROUND_WAIT_SECONDS}초 후 다음 라운드가 시작됩니다."
  end

  result
end
