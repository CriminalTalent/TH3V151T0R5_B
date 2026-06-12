# 전투 계산 로직
class BattleCalculator

  # 만할 타임라인에서의 사거리 계산
  # pos 형식: "A1", "B4", "C8" 등 (열=영문, 행=숫자)
  def self.distance(pos1, pos2)
    return 999 if pos1.to_s.empty? || pos2.to_s.empty?
    c1 = pos1[0].upcase.ord - 'A'.ord
    r1 = pos1[1..].to_i
    c2 = pos2[0].upcase.ord - 'A'.ord
    r2 = pos2[1..].to_i
    (c1 - c2).abs + (r1 - r2).abs
  end

  # 사거리 체크 (주위=1, 숫자=맨해튼 거리)
  def self.in_range?(range_str, pos1, pos2)
    return true if range_str.to_s == '자신'
    max_range = range_str.to_s == '주위' ? 1 : range_str.to_i
    distance(pos1, pos2) <= max_range
  end

  # 명중 판정
  def self.hit?(attacker_tec, target_spd, extra_dodge = 0)
    hit_rate = [100 + attacker_tec - target_spd - extra_dodge, 0].max
    roll = rand(1..100)
    puts "[명중] 명중률 #{hit_rate}% / 주사위 #{roll} → #{roll <= hit_rate ? '명중' : '회피'}"
    roll <= hit_rate
  end

  # 추가 대미지 다이스 [(속도+기술)d3]
  def self.roll_extra(spd, tec)
    dice_count = spd + tec
    return 0 if dice_count <= 0
    result = dice_count.times.sum { rand(1..3) }
    puts "[추가 대미지] #{dice_count}d3 = #{result}"
    result
  end

  # 크리티컬 판정 (행운 스탯 기반, 미구현시 0)
  def self.critical?(_luck)
    false  # 현재 전투 시스템에 크리티컬 없음
  end

  # 피격 대미지 계산
  # [(공격 수식) - 방어력] + 추가 대미지
  # 관통 스킬은 방어력 무시
  def self.calc_damage(base_attack, defender_def, extra_dmg, ignore_def: false)
    if ignore_def
      dmg = base_attack + extra_dmg
    else
      dmg = [base_attack - defender_def, 0].max + extra_dmg
    end
    dmg.ceil
  end

  # 보호막 처리
  def self.apply_shield(hp, shield, damage)
    if shield > 0
      remaining_shield = [shield - damage, 0].max
      actual_dmg = [damage - shield, 0].max
      new_hp = [hp - actual_dmg, 0].max
      [new_hp, remaining_shield]
    else
      [[hp - damage, 0].max, 0]
    end
  end

  # 스킬별 공격력 계산
  def self.calc_skill_damage(skill_name, base_atk)
    case skill_name
    when '기본공격', '저격', '관통', '폭격'
      base_atk
    when '강타'
      (base_atk * 1.5).ceil
    when '생사결단'
      (base_atk * 2.5).ceil
    else
      base_atk
    end
  end

  # 이동 거리 계산 (맨해튼)
  def self.move_cost(from_pos, to_pos)
    distance(from_pos, to_pos)
  end
end
