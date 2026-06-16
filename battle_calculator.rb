class BattleCalculator

  def self.parse_pos(pos)
    return nil if pos.to_s.strip.empty?
    col = pos[0].upcase.ord - 'A'.ord
    row = pos[1..].to_i - 1
    [col, row]
  end

  def self.distance(pos1, pos2)
    c1, r1 = parse_pos(pos1)
    c2, r2 = parse_pos(pos2)
    return 999 if c1.nil? || c2.nil?
    (c1 - c2).abs + (r1 - r2).abs
  end

  def self.in_range?(range_str, pos1, pos2)
    return true if range_str.to_s == '자신'
    return true if range_str.to_s == '-'
    max_range = range_str.to_s == '근접' ? 1 : range_str.to_i
    distance(pos1, pos2) <= max_range
  end

  def self.path_blocked?(from, to, ally_positions)
    fc, fr = parse_pos(from)
    tc, tr = parse_pos(to)
    return false if fc.nil? || tc.nil?
    dc = tc == fc ? 0 : (tc - fc) / (tc - fc).abs
    dr = tr == fr ? 0 : (tr - fr) / (tr - fr).abs
    return false unless dc == 0 || dr == 0
    c, r = fc + dc, fr + dr
    while [c, r] != [tc, tr]
      cell = "#{('A'.ord + c).chr}#{r + 1}"
      return true if ally_positions.include?(cell)
      c += dc
      r += dr
    end
    false
  end

  def self.in_front?(caster_pos, target_pos, facing)
    cc, cr = parse_pos(caster_pos)
    tc, tr = parse_pos(target_pos)
    return false if cc.nil? || tc.nil?
    case facing
    when '상' then tc == cc && tr == cr - 1
    when '하' then tc == cc && tr == cr + 1
    when '좌' then tr == cr && tc == cc - 1
    when '우' then tr == cr && tc == cc + 1
    else false
    end
  end

  def self.hit?(attacker_tec)
    hit_rate = [60 + attacker_tec, 0].max
    roll = rand(1..100)
    puts "[명중] 명중률 #{hit_rate}% / 주사위 #{roll} → #{roll <= hit_rate ? '명중' : '빗나감'}"
    roll <= hit_rate
  end

  def self.evade?(target_agi)
    evade_rate = target_agi * 2
    return false if evade_rate <= 0
    roll = rand(1..100)
    puts "[회피] 회피율 #{evade_rate}% / 주사위 #{roll} → #{roll <= evade_rate ? '회피' : '피격'}"
    roll <= evade_rate
  end

  def self.critical?(luck)
    crit_rate = luck * 2
    return false if crit_rate <= 0
    roll = rand(1..100)
    result = roll <= crit_rate
    puts "[크리티컬] 크리티컬률 #{crit_rate}% / 주사위 #{roll} → #{result ? '크리티컬!' : '일반'}"
    result
  end

  def self.calc_damage(base_attack, defender_dur, ignore_def: false)
    ignore_def ? [base_attack, 0].max : [base_attack - defender_dur, 0].max
  end

  def self.calc_skill_damage(skill_name, base_atk, is_critical: false, extra_params: {})
    if skill_name == '고육지책'
      sacrifice = extra_params[:hp_sacrifice] || 0
      bonus = (sacrifice / 10) * 5
      dmg = base_atk + bonus
      dmg = (dmg * 2).ceil if is_critical
      return dmg
    end
    multiplier = case skill_name
                 when '공격'      then 1.0
                 when '초인적인힘' then 2.0
                 when '흙뿌리기'  then 1.5
                 when '혼란'      then 1.0
                 when '습격'
                   dist = extra_params[:distance] || 0
                   dist >= 5 ? 2.5 : 1.5
                 when '폭발'      then 1.0
                 else 1.0
                 end
    dmg = (base_atk * multiplier).ceil
    dmg = (dmg * 2).ceil if is_critical
    dmg
  end

  def self.calc_heal(skill_name, base_atk, is_critical: false)
    multiplier = case skill_name
                 when '회복' then 0.2
                 when '활력' then 1.0
                 when '구원' then 0.5
                 else 0.0
                 end
    heal = (base_atk * multiplier).ceil
    heal = (heal * 2).ceil if is_critical
    heal
  end

  def self.move_cost(from_pos, to_pos)
    distance(from_pos, to_pos)
  end
end

class BattleCalculator
  def self.hit_detail(attacker_tec)
    rate = [[60 + attacker_tec.to_i, 0].max, 100].min
    roll = rand(1..100)
    success = roll <= rate
    puts "[명중] 명중률 #{rate}% / 주사위 #{roll} → #{success ? '명중' : '빗나감'}"
    { success: success, rate: rate, roll: roll }
  end

  def self.evade_detail(target_agi)
    rate = [[target_agi.to_i * 2, 0].max, 100].min
    return { success: false, rate: rate, roll: nil } if rate <= 0

    roll = rand(1..100)
    success = roll <= rate
    puts "[회피] 회피율 #{rate}% / 주사위 #{roll} → #{success ? '회피' : '피격'}"
    { success: success, rate: rate, roll: roll }
  end

  def self.critical_detail(luck)
    rate = [[luck.to_i * 2, 0].max, 100].min
    return { success: false, rate: rate, roll: nil } if rate <= 0

    roll = rand(1..100)
    success = roll <= rate
    puts "[크리티컬] 크리티컬률 #{rate}% / 주사위 #{roll} → #{success ? '크리티컬!' : '일반'}"
    { success: success, rate: rate, roll: roll }
  end

  def self.roll_text(label, detail)
    return "#{label} #{detail[:rate]}%" if detail[:roll].nil?
    "#{label} #{detail[:rate]}% / 주사위 #{detail[:roll]}"
  end
end
