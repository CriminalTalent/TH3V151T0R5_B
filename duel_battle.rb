# duel_battle.rb
# encoding: UTF-8
#
# 결투 2단계: 라운드 진행과 정산 (공격 / 방어 / 관찰).
# duel_manager.rb 의 DuelManager 클래스에 메서드를 더한다. 기존 settle_round 는 쓰지 않는다.
# 패시브, 나머지 스킬, 이동은 3단계에서 붙인다.

class DuelManager
  ACTION_RE = /\[(초인적인힘|고육지책|백발백중|주의분산|필사즉생|행운부여|위겐웰드 물약|디터니 원액|수상한 영약|순간이동|흙뿌리기|공격|방어|관찰|폭발|회복|활력|구원|강화|보호|응원|즉발|회피|철벽|혼란|습격|복수|희생)(?:\/([^\]]*))?\]/
  ACTION_WAIT_SECONDS = 300
  ROUND_PAUSE_SECONDS = 60
  MAX_IDLE_ROUNDS = 2

  private

  def lab(duel, name)
    st = duel.stats && duel.stats[name]
    shown = st ? st[:display_name].to_s.strip : ''
    shown.empty? ? name : shown
  end

  def team_of(duel, name)
    duel.team_a.any? { |n| n.casecmp?(name) } ? :a : :b
  end

  def alive_members(duel)
    members(duel).select { |n| duel.hp[n].to_i > 0 }
  end

  def resolve_member(duel, raw)
    key = raw.to_s.sub(/\A\s*@/, '').strip
    return nil if key.empty?

    squeeze = ->(s) { s.to_s.gsub(/\s+/, '').downcase }
    members(duel).find { |n| n.casecmp?(key) } ||
      members(duel).find do |n|
        st = duel.stats[n]
        st && !st[:display_name].to_s.strip.empty? && squeeze.call(st[:display_name]) == squeeze.call(key)
      end
  end

  def status_line(duel, view_sheet, name)
    st = duel.stats[name]
    hp = duel.hp[name].to_i
    max = st ? [st[:max_hp].to_i, hp].max : hp
    bar = view_sheet.respond_to?(:health_bar) ? view_sheet.health_bar(hp, max).to_s : ''
    count = bar.include?('/') ? '' : " #{hp}/#{max}"
    down = hp <= 0 ? ' — 전투불능' : ''
    "· #{lab(duel, name)} #{bar}#{count} (위치 #{duel.positions[name]})#{down}"
  end

  def handle_action(username, text, status)
    duel = duel_of(username)
    return unless duel && duel.phase == :battle

    name = canon(duel, username)
    m = text.match(ACTION_RE)
    return unless m

    type = m[1]
    raw_target = m[2].to_s.strip
    mark_reply(duel, status['id'])

    if duel.hp[name].to_i <= 0
      return reply_user(username, '전투불능 상태라 행동할 수 없습니다.', status)
    end
    if duel.actions[name]
      return reply_user(username, '이번 라운드 행동은 이미 입력했습니다.', status)
    end

    if type == '관찰'
      duel.actions[name] = { type: '관찰', target: nil }
      puts "[결투] [#{duel.id}] 행동 등록: @#{name} → 관찰"
      return
    end

    skill = BattleSkills.get(type)
    left = duel.cooldowns[name][type].to_i
    if left > 0
      return reply_user(username, "[#{type}]은(는) 아직 쿨타임 중입니다. (#{left}라운드 남음) 다른 행동을 입력해주세요.", status)
    end

    target = nil
    if type == '공격'
      enemies = alive_members(duel).reject { |n| team_of(duel, n) == team_of(duel, name) }
      if raw_target.empty?
        target = enemies.first if enemies.size == 1
        return reply_user(username, '공격 대상을 지정해주세요. 예: [공격/아이디]', status) unless target
      else
        target = resolve_member(duel, raw_target)
        unless target && team_of(duel, target) != team_of(duel, name)
          return reply_user(username, '공격할 상대를 찾을 수 없습니다. 상대 팀 참가자의 아이디를 확인해주세요.', status)
        end
        if duel.hp[target].to_i <= 0
          return reply_user(username, "#{lab(duel, target)}님은 이미 쓰러졌습니다.", status)
        end
      end
    else
      target = raw_target.empty? ? name : resolve_member(duel, raw_target)
      unless target && team_of(duel, target) == team_of(duel, name)
        return reply_user(username, '방어는 자신 또는 같은 팀에게만 사용할 수 있습니다.', status)
      end
    end

    unless BattleGrid.in_range?(duel.positions[name], duel.positions[target], skill[:range])
      return reply_user(username, "#{type}의 사거리 밖입니다. 현재 위치: #{duel.positions[name]}, 대상 위치: #{duel.positions[target]}", status)
    end

    duel.actions[name] = { type: type, target: target }
    puts "[결투] [#{duel.id}] 행동 등록: @#{name} → #{type}/#{target}"
  end

  def announce_round(duel, view_sheet)
    size = duel.team_a.size
    view = duel.dup
    view.positions = duel.positions.select { |n, _| duel.hp[n].to_i > 0 }
    text = "[결투 #{duel.round}라운드] #{size}:#{size}\n\n" \
           "[A팀]\n#{duel.team_a.map { |n| status_line(duel, view_sheet, n) }.join("\n")}\n\n" \
           "[B팀]\n#{duel.team_b.map { |n| status_line(duel, view_sheet, n) }.join("\n")}\n\n" \
           "전장\n\n#{render_grid(view, duel.stats.values).join("\n")}\n" \
           "───────────────────\n" \
           "DM 또는 멘션으로 행동을 입력해주세요.\n\n" \
           "형식:\n" \
           "공격: [공격/상대아이디]\n" \
           "방어: [방어/아이디] (생략하면 자신)\n" \
           "관찰: [관찰] (이번 라운드를 쉽니다)\n" \
           "스킬: [스킬명/대상] (지원·방어·공격 스킬 모두 사용 가능, 습격은 [습격/상대/도착좌표])\n" \
           "순간이동: [순간이동/좌표]\n" \
           "물약: [위겐웰드 물약/아이디] (소지품에 있을 경우)\n" \
           "입력 대기: 5분\n" \
           "───────────────────\n" \
           "※ 시험 단계: 그리핀도르 패시브1(정면)은 아직 지원하지 않습니다."
    response = post(duel, text)
    if response && response['id'] && !response['partial']
      duel.announced_round = true
      duel.round_started_at = Time.now
      duel.retry_after = nil
      puts "[결투] [#{duel.id}] #{duel.round}라운드 안내 송출"
    else
      duel.retry_after = Time.now + RETRY_SECONDS
      puts "[결투] [#{duel.id}] #{duel.round}라운드 안내 송출 실패 — #{RETRY_SECONDS}초 뒤 재시도"
    end
  end

  def settle_duel(duel, view_sheet, scout_sheet)
    size = duel.team_a.size
    round_no = duel.round
    alive = alive_members(duel)
    acted = alive.select { |n| duel.actions.key?(n) }
    log = []

    summary = alive.map do |n|
      act = duel.actions[n]
      desc =
        if act.nil? then '입력 없음 (턴 상실)'
        elsif act[:type] == '관찰' then '관찰'
        else "#{act[:type]} → #{lab(duel, act[:target])}"
        end
      "· #{lab(duel, n)}: #{desc}"
    end

    # 1) 방어
    guard = Hash.new(1.0)
    acted.each do |n|
      act = duel.actions[n]
      next unless act[:type] == '방어'

      skill = BattleSkills.get('방어')
      guard[act[:target]] *= skill[:ratio].to_f
      duel.cooldowns[n]['방어'] = skill[:cooldown].to_i + 1 if skill[:cooldown].to_i > 0
      log << "#{lab(duel, n)}의 방어 → #{lab(duel, act[:target])} 내구도 #{skill[:ratio]}배"
    end

    # 2) 공격 (동시 정산: 피해를 모아 두었다가 한꺼번에 반영한다)
    damage = Hash.new(0)
    acted.each do |n|
      act = duel.actions[n]
      next unless act[:type] == '공격'

      skill = BattleSkills.get('공격')
      t = act[:target]
      s = duel.stats[n]
      ts = duel.stats[t]
      an = lab(duel, n)
      tn = lab(duel, t)
      duel.cooldowns[n]['공격'] = skill[:cooldown].to_i + 1 if skill[:cooldown].to_i > 0

      log << ''
      log << "#{an}의 공격 → #{tn}"
      hit = BattleCalculator.hit_detail(s[:tec].to_i)
      log << "명중 #{hit[:rate]}% → #{hit[:roll]} (#{hit[:success] ? '명중' : '빗나감'})"
      unless hit[:success]
        log << "#{an}의 공격 빗나감"
        next
      end

      ev = BattleCalculator.evade_detail(ts[:agi].to_i)
      log << "회피 #{ev[:rate]}% → #{ev[:roll]} (#{ev[:success] ? '회피' : '피격'})" if ev && ev[:roll]
      if ev && ev[:success]
        log << "#{tn} 회피 — 피해 없음"
        next
      end

      cr = BattleCalculator.critical_detail(s[:luck].to_i)
      crit = cr && cr[:success]
      log << "크리티컬 #{cr[:rate]}% → #{cr[:roll]} (#{crit ? '크리티컬' : '일반'})" if cr && cr[:roll]

      scaled = (s[:atk].to_i * skill[:multiplier].to_f).ceil
      power = crit ? scaled * 2 : scaled
      eff_dur = (ts[:dur].to_i * guard[t]).to_i
      dmg = BattleCalculator.calc_damage(power, eff_dur)
      damage[t] += dmg
      log << "공격력 #{s[:atk].to_i} ×#{skill[:multiplier].to_f} = #{scaled}#{crit ? " (크리티컬 ×2 = #{power})" : ''}"
      log << "내구도 #{ts[:dur].to_i}#{guard[t] == 1.0 ? '' : " (방어 ×#{guard[t]} = #{eff_dur})"}"
      log << "실질 피해 #{dmg}"
    end

    # 3) 체력 반영
    before = duel.hp.dup
    damage.each { |t, d| duel.hp[t] = [duel.hp[t].to_i - d, 0].max }
    log << ''
    members(duel).each do |n|
      next if before[n] == duel.hp[n]

      log << "#{lab(duel, n)} 건강 #{before[n]} → #{duel.hp[n]}"
    end

    # 4) 쿨타임: 사용한 라운드에 N+1을 넣고 라운드 끝에 1을 빼서, N라운드를 쉬게 한다.
    duel.cooldowns.each_value do |h|
      h.keys.each do |k|
        h[k] = [h[k].to_i - 1, 0].max
        h.delete(k) if h[k] <= 0
      end
    end

    # 5) 체력을 시트에 쓰고, 쓰러진 참가자는 전투불능 표시를 붙인다.
    saved =
      begin
        view_sheet.update_runner_state(members(duel).map { |n| { name: n, hp: duel.hp[n].to_i } })
      rescue => e
        puts "[결투] 체력 시트 반영 오류: #{e.class}: #{e.message}"
        false
      end
    members(duel).each do |n|
      next unless before[n].to_i > 0 && duel.hp[n].to_i <= 0

      begin
        ScoutDirections.mark_incapacitated!(scout_sheet, n) if scout_sheet && defined?(ScoutDirections)
      rescue => e
        puts "[결투] 전투불능 표시 오류 @#{n}: #{e.class}: #{e.message}"
      end
    end

    # 6) 승패와 무응답
    a_alive = duel.team_a.any? { |n| duel.hp[n].to_i > 0 }
    b_alive = duel.team_b.any? { |n| duel.hp[n].to_i > 0 }
    ended = !(a_alive && b_alive)
    duel.idle_rounds = acted.empty? ? duel.idle_rounds.to_i + 1 : 0
    abandoned = !ended && duel.idle_rounds >= MAX_IDLE_ROUNDS

    result = ["[결투 #{round_no}라운드 결과] #{size}:#{size}", '', '행동', *summary,
              '────────────────────', '전투 로그']
    log.each { |line| result << (line.include?('→') ? "▶ #{line}" : line) }
    result << '────────────────────'
    result << '상태'
    members(duel).each { |n| result << status_line(duel, view_sheet, n) }
    result << ''
    result << '※ 체력 시트 반영에 실패했습니다. 운영자에게 알려주세요.' unless saved
    if ended
      if !a_alive && !b_alive
        result << '[무승부] 양 팀 모두 쓰러졌습니다.'
      else
        names = (a_alive ? duel.team_a : duel.team_b).map { |n| lab(duel, n) }.join(', ')
        result << "[승리] #{a_alive ? 'A' : 'B'}팀 (#{names})"
      end
      result << '※ 체력은 시트에 반영되었습니다. 쓰러진 참가자는 전투불능 상태가 됩니다.'
    elsif abandoned
      result << "[결투 종료] #{MAX_IDLE_ROUNDS}라운드 연속으로 아무도 행동하지 않아 결투를 종료합니다."
    else
      result << "#{ROUND_PAUSE_SECONDS}초 후 다음 라운드가 시작됩니다."
    end

    duel.pending_post = result.join("\n")
    duel.finishing = ended || abandoned
    duel.round += 1 unless duel.finishing
    duel.actions = {}
    duel.announced_round = false
    duel.next_round_at = nil
    duel.retry_after = nil
    puts "[결투] [#{duel.id}] #{round_no}라운드 정산 완료#{ended ? ' (결투 종료)' : ''}"
  end

  def tick_battle(duel, now, view_sheet, scout_sheet)
    return if duel.retry_after && now < duel.retry_after

    if duel.pending_post
      response = post(duel, duel.pending_post)
      if response && response['id'] && !response['partial']
        duel.pending_post = nil
        duel.retry_after = nil
        if duel.finishing
          @duels.delete(duel.id)
          puts "[결투] [#{duel.id}] 종료"
          return
        end
        duel.next_round_at = now + ROUND_PAUSE_SECONDS
      else
        duel.retry_after = now + RETRY_SECONDS
        puts "[결투] [#{duel.id}] 결과 안내 송출 실패 — #{RETRY_SECONDS}초 뒤 재시도"
      end
      return
    end

    return if duel.next_round_at && now < duel.next_round_at

    unless duel.announced_round
      announce_round(duel, view_sheet)
      return
    end

    alive = alive_members(duel)
    all_in = alive.all? { |n| duel.actions.key?(n) }
    timeout = (now - duel.round_started_at) >= ACTION_WAIT_SECONDS
    settle_duel(duel, view_sheet, scout_sheet) if all_in || timeout
  end
end
