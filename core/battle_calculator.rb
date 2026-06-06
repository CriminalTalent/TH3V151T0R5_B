# core/battle_calculator.rb

module BattleCalculator
  # 최대 HP: 체력 × 10
  def self.max_hp(user)
    (user["체력"] || 50).to_i * 10
  end

  # 공격력: 공격력 스탯 × 5
  def self.attack_power(user)
    (user["공격력"] || 10).to_i * 5
  end

  # 방어력: 방어력 스탯 × 5 (상시 차감, 커맨드 불필요)
  def self.defense_power(user)
    (user["방어력"] || 10).to_i * 5
  end

  # 추가 대미지: (속도 + 기술)d3 — 방어력 무시
  # d3 = rand(1..3)을 (속도+기술)번 굴려 합산
  def self.bonus_damage(user)
    dice_count = (user["속도"] || 0).to_i + (user["기술"] || 0).to_i
    return 0 if dice_count <= 0
    dice_count.times.sum { rand(1..3) }
  end

  # 명중 판정
  # 명중률 = 100 + 시전자기술 - 대상자속도
  # 결과가 100 이상이면 필중, 0 이하면 필회
  def self.hit_check(attacker, defender)
    rate = 100 + (attacker["기술"] || 0).to_i - (defender["속도"] || 0).to_i
    return true  if rate >= 100
    return false if rate <= 0
    rand(1..100) <= rate
  end

  # 명중률 수치 (표시용)
  def self.hit_rate(attacker, defender)
    rate = 100 + (attacker["기술"] || 0).to_i - (defender["속도"] || 0).to_i
    [[rate, 0].max, 100].min
  end

  # 크리티컬 판정: 행운/2 %
  def self.critical_check(user)
    chance = [(user["행운"] || 5).to_i.to_f / 2, 50].min
    rand(1..100) <= chance
  end

  # 피격 대미지
  # [(행동 커맨드 수식) - 방어력] + 추가 대미지
  # 관통 스킬 사용 시 방어력 무시 (ignore_defense: true)
  # 추가 대미지는 항상 방어력 무시
  def self.final_damage(raw_damage, defender, attacker, ignore_defense: false)
    def_val  = ignore_defense ? 0 : defense_power(defender)
    base_dmg = [raw_damage - def_val, 0].max
    bonus    = bonus_damage(attacker)
    { total: base_dmg + bonus, base: base_dmg, bonus: bonus }
  end

  # 회복량: 시전자 최대 체력의 40% (단일회복 기준)
  def self.heal_single(user)
    (max_hp(user) * 0.4).to_i
  end

  # 다중회복: 시전자 최대 체력의 30%
  def self.heal_multi(user)
    (max_hp(user) * 0.3).to_i
  end

  # 보호막: 시전자 최대 체력의 40%
  def self.shield_amount(user)
    (max_hp(user) * 0.4).to_i
  end

  # 행동력 초기화 (1라운드 1턴마다)
  INITIAL_AP = 5

  # 페이즈당 회복 행동력
  AP_REGEN = 2

  # HP 바
  def self.hp_bar(current_hp, max_hp)
    pct    = [current_hp.to_f / [max_hp, 1].max, 1.0].min
    filled = (pct * 10).round
    ("█" * filled) + ("░" * (10 - filled))
  end
end
