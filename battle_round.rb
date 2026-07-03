# encoding: UTF-8

def settle_round(battle_actions, runner_names, runner_sheet, creature_sheet, view_sheet, creature, ctx)
  runner_state = merge_runner_state(view_sheet, runner_sheet, runner_names, creature[:pos])
  base_stats   = runner_sheet.read_base_stats
  stats_of = ->(name) { base_stats.find { |s| s[:name] == name } || {} }
  state_of = ->(name) { runner_state.find { |r| r[:name] == name } }

  defended = {}
  log = []
  took_damage = {}

  atk_bonus  = Hash.new(0)
  dur_bonus  = Hash.new(0)
  tec_bonus  = Hash.new(0)
  luck_bonus = Hash.new(0)

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
    log << "[기숙사 패시브]"
    log.concat(passive_lines)
  end

  battle_actions.each do |name, act|
    next unless act[:type] == '회복'
    target_name = normalize_target(act[:target])
    target = state_of.call(target_name)
    next unless target
    if target[:hp].to_i <= 0
      log << "#{name} → #{target_name} 회복 실패 (이미 쓰러짐)"
      next
    end
    heal = [stats_of.call(name)[:atk].to_i + atk_bonus[name], 1].max
    before = target[:hp].to_i
    target[:hp] = [before + heal, target[:max_hp].to_i].min
    log << "#{name} → #{target_name} 회복 +#{target[:hp] - before}"
  end

  battle_actions.each do |name, act|
    next unless act[:type] == '방어'
    target_name = normalize_target(act[:target])
    defended[target_name] = true
    log << "#{name} → #{target_name} 방어 (받는 피해 절반)"
  end

  battle_actions.each do |name, act|
    next unless act[:type] == '공격'
    next if creature[:hp].to_i <= 0
    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    s = stats_of.call(name)

    unless BattleCalculator.hit?(s[:tec].to_i + tec_bonus[name])
      log << "#{name}의 공격 → 빗나감!"
      next
    end
    if BattleCalculator.evade?(creature[:agi].to_i)
      log << "#{name}의 공격 → #{creature[:name]} 회피!"
      next
    end

    crit = BattleCalculator.critical?(s[:luck].to_i + luck_bonus[name])
    eff_atk = s[:atk].to_i + atk_bonus[name]
    base = crit ? eff_atk * 2 : eff_atk
    dmg  = BattleCalculator.calc_damage(base, creature[:dur].to_i)
    creature[:hp] = [creature[:hp].to_i - dmg, 0].max
    log << "#{name}의 공격 → #{creature[:name]}에게 #{dmg} 피해#{crit ? ' (크리티컬!)' : ''}"
  end

  if creature[:hp].to_i > 0
    living = runner_state.select { |r| r[:hp].to_i > 0 && runner_names.include?(r[:name]) }
    if living.any?
      target = living.sample
      tname = target[:name]
      ts = stats_of.call(tname)

      unless BattleCalculator.hit?(creature[:tec].to_i)
        log << "#{creature[:name]}의 반격 → 빗나감!"
      else
        if BattleCalculator.evade?(ts[:agi].to_i)
          log << "#{creature[:name]}의 반격 → #{tname} 회피!"
        else
          crit = BattleCalculator.critical?(creature[:luck].to_i)
          base = crit ? creature[:atk].to_i * 2 : creature[:atk].to_i

          eff_dur = ts[:dur].to_i + dur_bonus[tname]
          if ts[:house].to_s.strip == '그리핀도르' && ts[:passive] == '1' &&
             BattleCalculator.in_front?(target[:pos], creature[:pos], ts[:facing].to_s)
            eff_dur = (eff_dur * 1.5).ceil
            log << "#{tname}: [그리핀도르] 공격자가 정면에 위치 — 내구도 1.5배"
          end

          dmg = BattleCalculator.calc_damage(base, eff_dur)
          dmg = dmg / 2 if defended[tname]

          if ts[:house].to_s.strip == '후플푸프' && ts[:passive] == '2' &&
             !ctx[:guard_used][tname] && target[:hp].to_i - dmg <= 0 && dmg > 0
            dmg = target[:hp].to_i - 1
            ctx[:guard_used][tname] = true
            log << "#{tname}: [후플푸프] 전투 중 1회 — 건강 0 이하 방지"
          end

          target[:hp] = [target[:hp].to_i - dmg, 0].max
          took_damage[tname] = true if dmg > 0
          line = "#{creature[:name]}의 반격 → #{tname}에게 #{dmg} 피해#{crit ? ' (크리티컬!)' : ''}"
          line += " [방어됨]" if defended[tname]
          log << line
          if target[:hp] <= 0
            target[:status] = '사망'
            log << "#{tname} 쓰러짐..."
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
