# battle_skills.rb
# encoding: UTF-8

module BattleSkills
  SKILLS = {
    '회복' => { category: '지원', range: '근접', cooldown: 1, kind: :heal, ratio: 0.2 },
    '활력' => { category: '지원', range: '2', cooldown: 1, kind: :heal, ratio: 1.0 },
    '구원' => { category: '지원', range: '2', cooldown: 2, kind: :heal_area, ratio: 0.5 },
    '강화' => { category: '지원', range: '3', cooldown: 2, kind: :atk_buff_area, ratio: 0.5 },
    '보호' => { category: '지원', range: '근접', cooldown: 2, kind: :shield, value: 30, max_targets: 3 },
    '백발백중' => { category: '지원', range: '3', cooldown: 2, kind: :sure_hit },
    '응원' => { category: '지원', range: '3', once: true, kind: :luck_buff, value: 10, turns: 2 },
    '즉발' => { category: '지원', range: '3', cooldown: 3, kind: :cooldown_reset },
    '행운부여' => { category: '지원', range: '-', cooldown: 0, kind: :force_move },

    '공격' => { category: '공격', range: '2', cooldown: 0, kind: :attack, multiplier: 1.0 },
    '초인적인힘' => { category: '공격', range: '2', cooldown: 2, kind: :attack, multiplier: 2.0 },
    '흙뿌리기' => { category: '공격', range: '1', cooldown: 4, kind: :attack_debuff, multiplier: 1.5, debuff: :atk_down_20_front },
    '혼란' => { category: '공격', range: '2', cooldown: 2, kind: :confusion, multiplier: 1.0 },
    '습격' => { category: '공격', range: '-', cooldown: 3, kind: :rush, multiplier: 1.5, long_multiplier: 2.5 },
    '폭발' => { category: '공격', range: '2', cooldown: 4, kind: :area_attack, multiplier: 1.0 },
    '고육지책' => { category: '공격', range: '1', once: true, kind: :sacrifice_attack, multiplier: 1.0 },
    '지정공격1인' => { category: '공격', range: '-', cooldown: 0, kind: :attack, multiplier: 2.5 },
    '지정공격다인' => { category: '공격', range: '-', cooldown: 0, kind: :area_attack, multiplier: 1.5 },
    '범위공격' => { category: '공격', range: '특정마스', cooldown: 0, kind: :area_attack, multiplier: 1.5, avoidable_by_move: true },
    '전체공격' => { category: '공격', range: '-', cooldown: 0, kind: :area_attack, multiplier: 1.0 },

    '방어' => { category: '방어', range: '근접', cooldown: 1, kind: :dur_guard, ratio: 1.5 },
    '회피' => { category: '방어', range: '자신', cooldown: 2, kind: :agi_buff_self, value: 20 },
    '복수' => { category: '방어', range: '근접', cooldown: 3, kind: :revenge, multiplier: 2.0 },
    '희생' => { category: '방어', range: '1', cooldown: 1, kind: :cover },
    '철벽' => { category: '방어', range: '근접', cooldown: 3, kind: :dur_buff_area, ratio: 0.5 },
    '주의분산' => { category: '방어', range: '근접', cooldown: 2, kind: :agi_buff_area, value: 15 },
    '필사즉생' => { category: '방어', range: '-', once: true, kind: :survive_once }
  }.freeze

  module_function

  def names
    SKILLS.keys
  end

  def command_regex
    names.map { |name| Regexp.escape(name) }.sort_by { |x| -x.length }.join('|')
  end

  def get(name)
    SKILLS[name.to_s.strip]
  end

  def category(name)
    get(name)&.dig(:category)
  end

  def support?(name)
    category(name) == '지원'
  end

  def attack?(name)
    category(name) == '공격'
  end

  def defense?(name)
    category(name) == '방어'
  end

  def cooldown_text(name)
    skill = get(name)
    return '-' unless skill
    return '전투 중 1회' if skill[:once]
    skill[:cooldown].to_s
  end
end
