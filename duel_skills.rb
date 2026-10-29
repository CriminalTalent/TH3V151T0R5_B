# duel_skills.rb
# encoding: UTF-8
#
# 결투 3-1단계 (입력 쪽): 지원/방어/공격 스킬, 순간이동, 전투 중 물약의 접수와 검증.
# duel_battle.rb 의 handle_action 을 대체한다.

class DuelManager
  DUEL_PENDING = %w[흙뿌리기 혼란 습격 복수 희생 필사즉생 행운부여].freeze

  private

  def duel_ctx(duel)
    duel.ctx ||= {
      buffs: Hash.new { |h, k| h[k] = [] },
      shields: Hash.new(0),
      sure_hit: {},
      once_used: Hash.new { |h, k| h[k] = {} },
      potion_used: []
    }
  end

  def enemies_of(duel, name)
    alive_members(duel).reject { |n| team_of(duel, n) == team_of(duel, name) }
  end

  def pick_enemy(duel, name, raw)
    list = enemies_of(duel, name)
    if raw.to_s.strip.empty?
      return [list.first, nil] if list.size == 1

      return [nil, '공격 대상을 지정해주세요. 예: [공격/아이디]']
    end
    target = resolve_member(duel, raw)
    unless target && team_of(duel, target) != team_of(duel, name)
      return [nil, '공격할 상대를 찾을 수 없습니다. 상대 팀 참가자의 아이디를 확인해주세요.']
    end
    return [nil, "#{lab(duel, target)}님은 이미 쓰러졌습니다."] if duel.hp[target].to_i <= 0

    [target, nil]
  end

  def pick_allies(duel, name, raw, limit, default_self: true)
    tokens = raw.to_s.split(',').map(&:strip).reject(&:empty?)
    return [[name], nil] if tokens.empty? && default_self
    return [nil, '대상을 지정해주세요.'] if tokens.empty?

    list = []
    tokens.first(limit).each do |tok|
      t = resolve_member(duel, tok)
      unless t && team_of(duel, t) == team_of(duel, name)
        return [nil, '같은 팀 참가자만 대상으로 지정할 수 있습니다. 아이디를 확인해주세요.']
      end
      return [nil, "#{lab(duel, t)}님은 이미 쓰러졌습니다."] if duel.hp[t].to_i <= 0

      list << t unless list.include?(t)
    end
    [list, nil]
  end

  def register_teleport(duel, name, username, raw, status)
    coord = raw.to_s.strip.upcase
    unless BattleGrid.valid_pos?(coord)
      return reply_user(username, '이동할 좌표가 올바르지 않습니다. 예: [순간이동/D4]', status)
    end

    from = duel.positions[name]
    return reply_user(username, '현재 위치와 같은 칸입니다.', status) if coord == from

    taken = alive_members(duel).find { |n| n != name && duel.positions[n] == coord }
    if taken
      return reply_user(username, "#{coord}에는 #{lab(duel, taken)}님이 있어 이동할 수 없습니다.", status)
    end

    duel.positions[name] = coord
    duel.actions[name] = { type: '순간이동', from: from, to: coord }
    puts "[결투] [#{duel.id}] 순간이동: @#{name} #{from} → #{coord}"
  end

  def handle_action(username, text, status)
    duel = duel_of(username)
    return unless duel && duel.phase == :battle

    name = canon(duel, username)
    m = text.match(ACTION_RE)
    return unless m

    type = m[1]
    raw = m[2].to_s.strip
    mark_reply(duel, status['id'])
    ctx = duel_ctx(duel)

    return reply_user(username, '전투불능 상태라 행동할 수 없습니다.', status) if duel.hp[name].to_i <= 0
    return reply_user(username, '이번 라운드 행동은 이미 입력했습니다.', status) if duel.actions[name]

    if DUEL_PENDING.include?(type)
      return reply_user(username, "[#{type}]은(는) 아직 결투에서 지원하지 않습니다.", status)
    end

    if type == '관찰'
      duel.actions[name] = { type: '관찰' }
      puts "[결투] [#{duel.id}] 행동 등록: @#{name} → 관찰"
      return
    end
    return register_teleport(duel, name, username, raw, status) if type == '순간이동'

    skill = BattleSkills.get(type)
    return reply_user(username, '알 수 없는 행동입니다.', status) unless skill

    if skill[:once] && ctx[:once_used][name][type]
      return reply_user(username, "[#{type}]은(는) 전투 중 1회만 사용할 수 있는 스킬입니다. 이미 사용했어요.", status)
    end
    left = duel.cooldowns[name][type].to_i
    if left > 0
      return reply_user(username, "[#{type}]은(는) 아직 쿨타임 중입니다. (#{left}라운드 남음) 다른 행동을 입력해주세요.", status)
    end

    parts = raw.split('/').map(&:strip).reject(&:empty?)
    act = { type: type }
    pos = duel.positions[name]
    range_fail = ->(t) { !BattleGrid.in_range?(pos, duel.positions[t], skill[:range]) }
    out_of_range = lambda do |t|
      "#{type}의 사거리 밖입니다. 현재 위치: #{pos}, 대상 위치: #{duel.positions[t]}"
    end

    case skill[:kind]
    when :attack, :area_attack, :sacrifice_attack
      target, err = pick_enemy(duel, name, parts[0])
      return reply_user(username, err, status) unless target
      return reply_user(username, out_of_range.call(target), status) if range_fail.call(target)

      act[:target] = target
      act[:cost] = parts[1].to_i if skill[:kind] == :sacrifice_attack
    when :heal_area, :atk_buff_area, :dur_buff_area, :agi_buff_area, :agi_buff_self
      act[:targets] = []
    when :dur_guard, :heal, :shield, :sure_hit, :luck_buff
      limit = skill[:max_targets] || ([:heal, :dur_guard].include?(skill[:kind]) ? 1 : 3)
      targets, err = pick_allies(duel, name, parts[0], limit)
      return reply_user(username, err, status) unless targets

      bad = targets.find { |t| range_fail.call(t) }
      return reply_user(username, out_of_range.call(bad), status) if bad

      act[:targets] = targets
    when :cooldown_reset
      targets, err = pick_allies(duel, name, parts[0], 3, default_self: false)
      return reply_user(username, err || '형식: [즉발/대상/스킬명]', status) unless targets

      reset_skill = parts[1].to_s.strip
      if reset_skill.empty?
        return reply_user(username, '초기화할 스킬명을 입력해주세요. 예: [즉발/아이디/철벽]', status)
      end
      bad = targets.find { |t| range_fail.call(t) }
      return reply_user(username, out_of_range.call(bad), status) if bad

      targets.each { |t| duel.cooldowns[t].delete(reset_skill) }
      puts "[결투] [#{duel.id}] 즉발 즉시효과: @#{name} → #{targets.join(', ')}의 [#{reset_skill}] 쿨타임 초기화"
      act[:targets] = targets
      act[:reset_skill] = reset_skill
    when :heal_fixed
      targets, err = pick_allies(duel, name, parts[0], 1)
      return reply_user(username, err, status) unless targets

      if BattleItems.owned?(username, type) == false
        return reply_user(username, "소지품에 #{type}이(가) 없습니다.", status)
      end

      act[:targets] = targets
    else
      return reply_user(username, "[#{type}]은(는) 아직 결투에서 지원하지 않습니다.", status)
    end

    duel.actions[name] = act
    puts "[결투] [#{duel.id}] 행동 등록: @#{name} → #{type}"
  end
end
