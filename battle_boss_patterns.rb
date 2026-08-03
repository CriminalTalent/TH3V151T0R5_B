# battle_boss_patterns.rb
# encoding: UTF-8

module BattleBossPatterns
  module_function

  def pattern_name(creature)
    creature[:current_skill].to_s.strip.empty? ? creature[:pattern].to_s.strip : creature[:current_skill].to_s.strip
  end

  def pattern_cells(creature)
    BattleGrid.parse_cell_list(
      creature[:skill_range].to_s.empty? ?
        (creature[:pattern_cells] || creature[:패턴범위] || creature[:범위]) :
        creature[:skill_range]
    )
  end

  def skill_target(creature)
    creature[:skill_target].to_s.strip.gsub('@', '')
  end

  def debuff_name(creature)
    creature[:debuff].to_s.strip
  end

  def skill_category(creature)
    creature[:skill_category].to_s.strip
  end

  def range_shape(creature)
    creature[:range_shape].to_s.strip
  end

  def skill_description(creature)
    creature[:skill_desc].to_s.strip
  end

  def pattern_multiplier(creature)
    value = creature[:pattern_multiplier].to_f
    value > 0 ? value : 1.0
  end

  def target_count(creature)
    value = creature[:target_count].to_i
    value > 0 ? value : 1
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
      add_stat_debuff!(ctx, target_name, :dur, 10, 2)
      log << "#{target_name}: 취약 — 내구도 -10 (2턴)"
    when '기절'
      ctx[:stun] ||= {}
      ctx[:stun][target_name] = 1
      log << "#{target_name}: 기절 — 다음 행동 불가"
    end
  end

  def pattern_damage(creature, multiplier)
    formula = creature[:damage_formula].to_s.strip
    magic = creature[:atk].to_i

    case formula
    when /고정\s*(\d+)/
      Regexp.last_match(1).to_i
    when /마법\s*[x×*]\s*([0-9.]+)/
      (magic * Regexp.last_match(1).to_f).ceil
    when /마법능력\s*[x×*]\s*([0-9.]+)/
      (magic * Regexp.last_match(1).to_f).ceil
    else
      base = (magic * multiplier.to_f).ceil
      base <= 0 ? 0 : base
    end
  end

  def range_text(cells)
    cells.to_a.map(&:to_s).map(&:upcase).reject(&:empty?).join(' · ')
  end

  def apply_pattern_damage_to_runner!(log, runner, creature, raw_power, debuff, ctx, stats_of:, dur_bonus:, defended_multiplier:, shields:, took_damage:, agi_bonus: nil, runner_state: nil)
    name = runner[:name]
    dname = runner[:display_name].to_s.strip
    dname = name.to_s if dname.empty?

    redirected = false
    cover_name = ctx[:cover] ? ctx[:cover][name] : nil
    if cover_name && runner_state
      cover_runner = runner_state.find { |r| r[:name].to_s == cover_name.to_s }
      if cover_runner && cover_runner[:hp].to_i > 0
        cover_dname = cover_runner[:display_name].to_s.strip
        cover_dname = cover_name.to_s if cover_dname.empty?
        log << "#{cover_dname} → [희생] #{dname} 대신 피격"
        runner = cover_runner
        name = runner[:name]
        dname = cover_dname
        redirected = true
      end
    end

    if !redirected && ctx[:survive_once] && runner_state
      # 지정 커버(희생)가 없으면, 이번 라운드 필사즉생을 쓴 사람이 있을 경우
      # 대신 맞아준다 (파티 전체를 대상으로 하는 공격도 전부 흡수).
      guardian_name = ctx[:survive_once].to_a.find { |_n, active| active }&.first
      if guardian_name && guardian_name.to_s != name.to_s
        guardian_runner = runner_state.find { |r| r[:name].to_s == guardian_name.to_s }
        if guardian_runner && guardian_runner[:hp].to_i > 0
          guardian_dname = guardian_runner[:display_name].to_s.strip
          guardian_dname = guardian_name.to_s if guardian_dname.empty?
          log << "#{guardian_dname} → [필사즉생] #{dname} 대신 피격"
          runner = guardian_runner
          name = runner[:name]
          dname = guardian_dname
        end
      end
    end

    stats = stats_of ? stats_of.call(name) : {}

    hit_detail = BattleCalculator.hit_detail(creature[:tec].to_i)
    log << "명중 #{hit_detail[:rate]}% → #{hit_detail[:roll]} (#{hit_detail[:success] ? '명중' : '빗나감'})"
    unless hit_detail[:success]
      log << "#{dname} 회피 — 피해 없음"
      log << ''
      return 0
    end

    # 회피 판정: 보스의 모든 피해 패턴에 자동 적용 (민첩 버프 포함)
    base_agi = stats[:agi].to_i
    base_agi = runner[:agi].to_i if base_agi <= 0 && runner[:agi]
    eff_agi = base_agi + (agi_bonus ? agi_bonus[name].to_i : 0)
    evade_detail = BattleCalculator.evade_detail(eff_agi)
    if evade_detail[:roll]
      log << "#{dname} 회피 #{evade_detail[:rate]}% → #{evade_detail[:roll]} (#{evade_detail[:success] ? '회피' : '피격'})"
    end
    if evade_detail[:success]
      log << "#{dname} 회피 — 피해 없음"
      log << ''
      return 0
    end

    base_dur = stats[:dur].to_i
    base_dur = runner[:dur].to_i if base_dur <= 0 && runner[:dur]
    eff_dur = base_dur + (dur_bonus ? dur_bonus[name].to_i : 0)
    eff_dur = (eff_dur * (defended_multiplier ? defended_multiplier[name].to_f : 1.0)).ceil

    dmg = BattleCalculator.calc_damage(raw_power.to_i, eff_dur.to_i)

    if shields && shields[name].to_i > 0 && dmg > 0
      blocked = [shields[name].to_i, dmg].min
      shields[name] -= blocked
      dmg -= blocked
      log << "#{name} 보호막 #{blocked} 흡수"
    end

    # 필사즉생: 이번 턴 건강이 0 이하로 떨어지는 것을 방지 (라운드가 끝날 때까지
    # 몇 번을 대신 맞든 계속 보호되며, 라운드 종료 시 1회 소모로 초기화된다).
    if ctx[:survive_once] && ctx[:survive_once][name] && runner[:hp].to_i - dmg <= 0 && dmg > 0
      overkill = dmg > runner[:hp].to_i
      dmg = runner[:hp].to_i - 1
      log << "#{dname}: 필사즉생으로 건강 0 이하 방지"
      if overkill && !(stats[:house].to_s.strip == '후플푸프' && stats[:passive].to_s == '2')
        ctx[:survive_penalty] ||= {}
        ctx[:survive_penalty][name] = true
        log << "#{dname}: 받은 피해가 잔여 건강을 초과하여 다음 라운드 행동할 수 없습니다"
      elsif overkill
        log << "#{dname}: [후플푸프] 필사즉생 후유증 면제 — 다음 라운드도 정상 행동 가능"
      end
    end

    runner[:hp] = [runner[:hp].to_i - dmg, 0].max
    took_damage[name] = true if took_damage && dmg > 0

    log << "-#{name}"
    log << "피해:#{dmg}"
    log << "HP: #{runner[:hp].to_i + dmg} → #{runner[:hp]}"

    apply_debuff!(log, ctx, name, debuff)

    if runner[:hp].to_i <= 0
      runner[:status] = '전투불가'
      log << "#{name} 전투불가"
    end

    dmg
  end

  def log_skill_header(log, creature, name, raw_power, range_label, debuff)
    log << "▶ #{creature[:name]}의 #{name}"
    log << "위력: #{raw_power}" if raw_power.to_i > 0
    log << "범위: #{range_label}" unless range_label.to_s.strip.empty?
    log << "디버프: #{debuff}" unless debuff.to_s.strip.empty?
    desc = skill_description(creature)
    log << desc unless desc.empty?
    log << ''
  end

  def living_runners(runner_state)
    runner_state.select { |runner| runner[:hp].to_i > 0 }
  end

  def targets_by_cells(runner_state, cells)
    living_runners(runner_state).select do |runner|
      cells.include?(runner[:pos].to_s.upcase)
    end
  end

  def targets_by_name(runner_state, target_name)
    target_names = target_name.to_s.split(',').map { |name| name.to_s.strip.gsub('@', '') }.reject(&:empty?)
    return [] if target_names.empty?

    living_runners(runner_state).select do |runner|
      target_names.include?(runner[:name].to_s)
    end
  end

  def random_targets(runner_state, count = 1)
    living_runners(runner_state).sample(count.to_i <= 0 ? 1 : count.to_i)
  end

  def apply_pattern!(log, runner_state, creature, ctx, stats_of: nil, dur_bonus: nil, defended_multiplier: nil, shields: nil, took_damage: nil, agi_bonus: nil)
    name = pattern_name(creature)
    return false if name.empty? || name == '-'

    category = skill_category(creature)
    cells = pattern_cells(creature)
    target_name = skill_target(creature)
    debuff = debuff_name(creature)
    multiplier = pattern_multiplier(creature)
    raw_power = pattern_damage(creature, multiplier)
    shape = range_shape(creature)

    # 현재스킬이 범위공격/전체공격/디버프가 아니더라도 보스스킬 탭의 분류/범위/대상으로 처리합니다.
    if name == '전체공격' || shape == '전체' || creature[:skill_range_default].to_s.strip == '전체'
      log_skill_header(log, creature, name, raw_power, '전체', debuff)
      targets = living_runners(runner_state)

      if targets.empty?
        log << '대상 없음'
        log << '피해 없음'
      else
        targets.each do |runner|
          apply_pattern_damage_to_runner!(
            log, runner, creature, raw_power, debuff, ctx,
            stats_of: stats_of,
            dur_bonus: dur_bonus,
            defended_multiplier: defended_multiplier,
            shields: shields,
            took_damage: took_damage,
            agi_bonus: agi_bonus
          )
        end
      end

      return true
    end

    if name == '디버프' || category == '디버프'
      return false if cells.empty? && target_name.empty?
      range_label = cells.empty? ? target_name : range_text(cells)
      log_skill_header(log, creature, name, 0, range_label, debuff)
      targets = cells.empty? ? targets_by_name(runner_state, target_name) : targets_by_cells(runner_state, cells)

      if targets.empty?
        log << '대상 없음'
        log << '피해 없음'
      else
        targets.each { |runner| apply_debuff!(log, ctx, runner[:name], debuff) }
      end

      return true
    end

    # 공격 스킬: 스킬범위 좌표가 있으면 해당 칸, 스킬대상이 있으면 해당 러너.
    # 둘 다 비어 있으면 기본 공격처럼 살아있는 러너 1명을 무작위 대상으로 삼습니다.
    targets = []
    range_label = ''

    if cells.any?
      targets = targets_by_cells(runner_state, cells)
      range_label = range_text(cells)
    elsif !target_name.empty?
      targets = targets_by_name(runner_state, target_name)
      range_label = target_name
    elsif name == '지정공격다인'
      targets = random_targets(runner_state, target_count(creature))
      range_label = targets.map { |t| t[:name].to_s }.join(', ')
    else
      targets = random_targets(runner_state, 1)
      range_label = targets.map { |t| t[:name].to_s }.join(', ')
    end

    log_skill_header(log, creature, name, raw_power, range_label, debuff)

    if targets.empty?
      log << '대상 없음'
      log << '피해 없음'
    else
      targets.each do |runner|
        apply_pattern_damage_to_runner!(
          log, runner, creature, raw_power, debuff, ctx,
          stats_of: stats_of,
          dur_bonus: dur_bonus,
          defended_multiplier: defended_multiplier,
          shields: shields,
          took_damage: took_damage,
          agi_bonus: agi_bonus
        )
      end
    end

    true
  end
end
