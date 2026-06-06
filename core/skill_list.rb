# core/skill_list.rb
# 스킬 목록 및 메타데이터

module SkillList
  # 분류: :attack / :support / :standby
  # 사거리: 숫자 / :self / :around (주위)
  # ap_cost: 소모 행동력
  # cooldown: 라운드 쿨타임 (0 = 없음)
  # special: 특수 스킬 여부 (전투 회차당 1회, 팀당 2개 중복 제한)

  SKILLS = {
    # ── 기본 스킬 ─────────────────────────────────────────
    "기본공격" => {
      category: :attack,   range: 1, ap_cost: 1, cooldown: 0, special: false,
      desc: "자신의 공격력으로 공격한다."
    },
    "반격태세" => {
      category: :standby,  range: :self, ap_cost: 1, cooldown: 0, special: false,
      desc: "공격 대상이 되었을 경우 자신의 공격력으로 반격한다. 방어 및 추가 대미지 적용. 시전자 사망 시에도 반격 대미지 적용."
    },
    "방어태세" => {
      category: :standby,  range: :self, ap_cost: 1, cooldown: 0, special: false,
      desc: "자신의 피격 대미지를 20% 감소시킨다."
    },
    "회피" => {
      category: :standby,  range: :self, ap_cost: 2, cooldown: 0, special: false,
      desc: "자신의 회피율에 50%를 더한다."
    },
    "대상이동" => {
      category: :support,  range: 3, ap_cost: 4, cooldown: 0, special: false,
      desc: "사거리 내의 아군 1인을 시전자의 사거리 이내에 재배치한다. 지원 스킬 중 가장 마지막 정산."
    },
    "행동지원" => {
      category: :support,  range: 2, ap_cost: 2, cooldown: 0, special: false,
      desc: "해당 아군 페이즈, 사용 즉시 사거리 내의 아군 1인의 행동력에 2를 더한다."
    },

    # ── 선택 스킬 ─────────────────────────────────────────
    "저격" => {
      category: :attack,   range: 2, ap_cost: 3, cooldown: 0, special: false,
      desc: "사거리 내의 대상 1인을 공격력으로 공격. 반격 불가."
    },
    "강타" => {
      category: :attack,   range: 1, ap_cost: 2, cooldown: 0, special: false,
      desc: "사거리 내의 대상 1인을 공격력×1.5로 공격."
    },
    "관통" => {
      category: :attack,   range: 1, ap_cost: 3, cooldown: 0, special: false,
      desc: "사거리 내의 대상 1인을 공격력으로 공격. 방어력 무시.",
      ignore_defense: true
    },
    "폭격" => {
      category: :attack,   range: :around, ap_cost: 2, cooldown: 0, special: false,
      desc: "사거리 내의 적군 3인을 공격력으로 공격."
    },
    "경호" => {
      category: :support,  range: :around, ap_cost: 2, cooldown: 0, special: false,
      desc: "사거리 내의 아군 1인 보호. 다음 적군 페이즈, 해당 아군 공격을 대신 받음."
    },
    "보호" => {
      category: :support,  range: 2, ap_cost: 2, cooldown: 0, special: false,
      desc: "사거리 내 아군 1인 또는 자신에게 최대 체력 40% 보호막 부여. 중첩 불가, 갱신 가능."
    },
    "회피지원" => {
      category: :support,  range: 2, ap_cost: 3, cooldown: 0, special: false,
      desc: "다음 적군 페이즈, 사거리 내 아군(자신 포함) 3인에게 회피율 +20%. 중첩 불가."
    },
    "방어지원" => {
      category: :support,  range: 2, ap_cost: 3, cooldown: 0, special: false,
      desc: "다음 적군 페이즈, 사거리 내 아군(자신 포함) 3인 방어력 +15. 중첩 불가."
    },
    "공격지원" => {
      category: :support,  range: 2, ap_cost: 3, cooldown: 0, special: false,
      desc: "해당 아군 페이즈, 사거리 내 아군 3인 공격력 +15. 중첩 불가."
    },
    "회복" => {
      category: :support,  range: 2, ap_cost: 2, cooldown: 0, special: false,
      desc: "사거리 내 지정 아군(자신 포함) 1인을 시전자 최대 체력의 40%만큼 회복."
    },
    "다중회복" => {
      category: :support,  range: 2, ap_cost: 3, cooldown: 0, special: false,
      desc: "사거리 내 지정 아군(자신 포함) 3인을 시전자 최대 체력의 30%만큼 회복."
    },

    # ── 특수 스킬 ─────────────────────────────────────────
    "불굴의 의지" => {
      category: :support,  range: :around, ap_cost: 2, cooldown: 0, special: true,
      desc: "사거리 내 아군(자신 포함) 3인 보호. 다음 적군 페이즈 공격 대신 받음. 다음 턴 체력 1 이하로 떨어지지 않음."
    },
    "소생술" => {
      category: :support,  range: :around, ap_cost: 2, cooldown: 0, special: true,
      desc: "사망 아군 1인을 사거리 내 빈 칸에 부활. 최대 체력/행동력 5로 복귀, 해당 턴 즉시 행동 가능."
    },
    "신의 가호" => {
      category: :support,  range: 3, ap_cost: 2, cooldown: 0, special: true,
      desc: "다음 적군 페이즈, 사거리 내 모든 아군+자신 방어력을 시전자 방어력의 50%만큼 상승."
    },
    "속박의 낙인" => {
      category: :support,  range: :around, ap_cost: 2, cooldown: 0, special: true,
      desc: "다음 적군 페이즈, 사거리 내 적군 전원의 이동 및 스킬 사용 봉쇄."
    },
    "천사의 노래" => {
      category: :support,  range: 2, ap_cost: 2, cooldown: 0, special: true,
      desc: "사거리 내 지정 아군 3인 또는 자신을 최대 체력까지 회복."
    },
    "생사결단" => {
      category: :attack,   range: 1, ap_cost: 2, cooldown: 0, special: true,
      desc: "사거리 내 대상 1인을 공격력×2.5로 공격. 타격 대미지의 30%만큼 반동 피해(방어력/보호 무시)."
    }
  }.freeze

  BASIC_SKILLS   = SKILLS.select { |_, v| !v[:special] && [:standby, :support].include?(v[:category]) ||
                                           !v[:special] && v[:category] == :attack &&
                                           ["기본공격", "반격태세", "방어태세", "회피", "대상이동", "행동지원"].include?(_) }.keys
  SELECT_SKILLS  = %w[저격 강타 관통 폭격 경호 보호 회피지원 방어지원 공격지원 회복 다중회복].freeze
  SPECIAL_SKILLS = SKILLS.select { |_, v| v[:special] }.keys.freeze

  def self.get(name)
    SKILLS[name]
  end

  def self.ap_cost(name)
    SKILLS.dig(name, :ap_cost) || 1
  end

  def self.special?(name)
    SKILLS.dig(name, :special) || false
  end

  def self.category(name)
    SKILLS.dig(name, :category)
  end
end
