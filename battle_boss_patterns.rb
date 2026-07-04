# battle_boss_patterns.rb
# encoding: UTF-8

module BattleBossPatterns
  module_function

  def pattern_name(creature)
    creature[:current_skill].to_s.strip.empty? ? creature[:pattern].to_s.strip : creature[:current_skill].to_s.strip
  end

  def pattern_cells(creature)
    # 스킬범위/패턴범위는 실제 스킬 판정에만 사용하고, 전장에는 표시하지 않습니다.
    BattleGrid.parse_cell_list(
      creature[:skill_range].to_s.empty? ?
        (creature[:pattern_cells] || creature[:패턴범위] || creature[:범위]) :
        creature[:skill_range]
    )
  end

  def skill_target(creature)
    creature[:skill_target].to_s.strip
  end

  def debuff_name(creature)
    creature[:debuff].to_s.strip
  end

  def pattern_multiplier(creature)
    value = creature[:pattern_multiplier].to_f
    value > 0 ? value : 1.0
  end

  def apply_ongoing_debuffs!(log, runner_state, ctx)
    ctx[:debuffs] ||= Hash.new { |h, k| h[k] = [] }

    runner_state.each do |runner|
      name = runner[:name]
      next unless runner[:hp].to_i > 0

      active = ctx[:debuffs][name].to_a
      next if active.empty?

      active.each do |debuff|
        case debuff[:type]
        when :poison
          dmg = debuff[:value].to_i <= 0 ? 5 : debuff[:value].to_i
          runner[:hp] = [runner[:hp].to_i - dmg, 0].max
          log << "#{name}: 독 피해 #{dmg}"
        end
        debuff[:turns] = debuff[:turns].to_i - 1
      end

      ctx[:debuffs][name] = active.reject { |d| d[:turns].to_i <= 0 }
    end
  end

  def add_stat_debuff!(ctx, target_name, stat, amount, turns)
    ctx[:buffs][target_name] << {
      stat: stat,
      value: -amount.to_i.abs,
      turns: turns.to_i <= 0 ? 1 : turns.to_i
    }
  end

  def apply_debuff!(log, ctx, target_name, debuff)
    return if target_name.to_s.empty? || debuff.to_s.strip.empty?

    case debuff.to_s.strip
    when '독'
      ctx[:debuffs] ||= Hash.new { |h, k| h[k] = [] }
      ctx[:debuffs][target_name] << { type: :poison, value: 5, turns: 3 }
      log << "#{target_name}: 독 부여 (3턴)"
    when '둔화'
      add_stat_debuff!(ctx, target_name, :agi, 10, 2)
      log << "#{target_name}: 둔화 — 민첩 -10 (2턴)"
    when '약화'
      add_stat_debuff!(ctx, target_name, :atk, 10, 2)
      log << "#{target_name}: 약화 — 마법능력 -10 (2턴)"
    when '취약'
      # 피해 증가형은 다음 단계에서 정밀화. 현재는 내구도 감소로 처리.
      add_stat_debuff!(ctx, target_name, :dur, 10, 2)
      log << "#{target_name}: 취약 — 내구도 -10 (2턴)"
    when '기절'
      ctx[:stun] ||= {}
      ctx[:stun][target_name] = 1
      log << "#{target_name}: 기절 — 다음 행동 불가"
    end
  end

  def pattern_damage(creature, multiplier)
    base = (creature[:atk].to_i * multiplier.to_f).ceil
    base <= 0 ? 0 : base
  end

  def apply_pattern!(log, runner_state, creature, ctx)
    name = pattern_name(creature)
    return if name.empty? || name == '-'

    cells = pattern_cells(creature)
    debuff = debuff_name(creature)
    multiplier = pattern_multiplier(creature)

    log << "#{creature[:name]}의 이번 턴 스킬: #{name}"

    case name
    when '범위공격'
      return if cells.empty?
      log << "#{creature[:name]}의 범위공격"
      runner_state.each do |runner|
        next unless runner[:hp].to_i > 0
        next unless cells.include?(runner[:pos].to_s.upcase)

        dmg = pattern_damage(creature, multiplier <= 0 ? 1.5 : multiplier)
        runner[:hp] = [runner[:hp].to_i - dmg, 0].max
        log << "#{runner[:name]} → 범위공격 #{dmg} 피해"
        apply_debuff!(log, ctx, runner[:name], debuff)
      end
    when '전체공격'
      log << "#{creature[:name]}의 전체공격"
      runner_state.each do |runner|
        next unless runner[:hp].to_i > 0
        dmg = pattern_damage(creature, multiplier)
        runner[:hp] = [runner[:hp].to_i - dmg, 0].max
        log << "#{runner[:name]} → 전체공격 #{dmg} 피해"
        apply_debuff!(log, ctx, runner[:name], debuff)
      end
    when '디버프'
      return if cells.empty?
      log << "#{creature[:name]}의 디버프"
      runner_state.each do |runner|
        next unless runner[:hp].to_i > 0
        next unless cells.include?(runner[:pos].to_s.upcase)
        apply_debuff!(log, ctx, runner[:name], debuff)
      end
    end
  end
end
