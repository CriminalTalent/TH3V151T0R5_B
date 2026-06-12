class BattleCalculator

  def self.distance(pos1, pos2)
    return 999 if pos1.to_s.empty? || pos2.to_s.empty?
    c1 = pos1[0].upcase.ord - 'A'.ord
    r1 = pos1[1..].to_i
    c2 = pos2[0].upcase.ord - 'A'.ord
    r2 = pos2[1..].to_i
    (c1 - c2).abs + (r1 - r2).abs
  end

  def self.in_range?(range_str, pos1, pos2)
    return true if range_str.to_s == '자신'
    return true if range_str.to_s == '-'
    max_range = range_str.to_s == '근접' ? 1 : range_str.to_i
    distance(pos1, pos2) <= max_range
  end

  # 명중 판정 - 기본 60%
  def self.hit?(attacker_tec, target_agi, extra_dodge = 0)
    hit_rate = [60 + attacker_tec - extra_dodge, 0].max
    roll = rand(1..100)
    puts "[명중] 명중률 #{hit_rate}% / 주사위 #{roll} → #{roll <= hit_rate ? '명중' : '빗나감'}"
    roll <= hit_rate
  end

  # 회피 판정 - 민첩 기반 자동
  def self.evade?(target_agi)
    evade_rate = target_agi * 2
    return false if evade_rate <= 0
    roll = rand(1..100)
    puts "[회피] 회피율 #{evade_rate}% / 주사위 #{roll} → #{roll <= evade_rate ? '회피' : '피격'}"
    roll <= evade_rate
  end

  # 크리티컬 판정 - 행운 기반 자동
  def self.critical?(luck)
    crit_rate = luck * 2
    return false if crit_rate <= 0
    roll = rand(1..100)
    result = roll <= crit_rate
    puts "[크리티컬] 크리티컬률 #{crit_rate}% / 주사위 #{roll} → #{result ? '크리티컬!' : '일반'}"
    result
  end

  # 피격 대미지: (공격 수식) - 내구도
  def self.calc_damage(base_attack, defender_dur, ignore_def: false)
    if ignore_def
      [base_attack, 0].max
    else
      [base_attack - defender_dur, 0].max
    end
  end

  # 스킬별 공격 배율 적용
  def self.calc_skill_damage(skill_name, base_atk, is_critical: false, extra_params: {})
    multiplier = case skill_name
    when '공격'        then 1.0
    when '초인적인 힘'  then 2.0
    when '흙 뿌리기'   then 1.5
    when '혼란'        then 1.0
    when '습격'
      dist = extra_params[:distance] || 0
      dist >= 5 ? 2.5 : 1.5
    when '폭발'        then 1.0
    when '고육지책'
      sacrifice = extra_params[:hp_sacrifice] || 0
      bonus = (sacrifice / 10) * 5
      return base_atk + bonus
    else 1.0
    end

    dmg = (base_atk * multiplier).ceil
    dmg = base_atk * 2 if is_critical  # 크리티컬: 마법능력 2배
    dmg
  end

  # 회복량 계산
  def self.calc_heal(skill_name, base_atk, is_critical: false)
    multiplier = case skill_name
    when '회복'   then 0.2
    when '활력'   then 1.0
    when '구원'   then 0.5
    when '강화'   then 0.5  # 강화는 공격력 증가
    else 0.0
    end
    heal = (base_atk * multiplier).ceil
    heal = (base_atk * multiplier * 2).ceil if is_critical
    heal
  end

  def self.move_cost(from_pos, to_pos)
    distance(from_pos, to_pos)
  end
end
