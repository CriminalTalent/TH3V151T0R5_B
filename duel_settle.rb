# duel_settle.rb
# encoding: UTF-8
#
# 결투 3-1단계 (정산 쪽). duel_battle.rb 의 settle_duel 을 대체한다.
# 순서는 기존 전투와 같다: 지원 → 방어 → 공격 → 체력 반영.
# 3-2 에서 기숙사 패시브를 보너스 계산 직후에 더한다.

class DuelManager
  SHIELDS_PERSIST = false # true 면 보호막이 라운드를 넘어 남는다

  private

  def stat_of(duel, name)
    duel.stats[name] || {}
  end

  def max_hp_of(duel, name, start_hp)
    m = stat_of(duel, name)[:max_hp].to_i
    m > 0 ? m : [duel.hp[name].to_i, start_hp[name].to_i].max
  end

  def buff_bonus(ctx, name, stat)
    ctx[:buffs][name].select { |b| b[:stat] == stat }.sum { |b| b[:value].to_i }
  end

  def duel_gate!(duel, ctx, log, name, type, skill, dname)
    if skill[:once]
      if ctx[:once_used][name][type]
        log << "#{dname}의 #{type} → 이미 사용한 전투 중 1회 스킬"
        return false
      end
      ctx[:once_used][name][type] = true
      return true
    end

    cd = skill[:cooldown].to_i
    return true if cd <= 0

    left = duel.cooldowns[name][type].to_i
    if left > 0
      log << "#{dname}의 #{type} → 쿨타임 #{left}라운드 남음 (행동 무효)"
      return false
    end
    duel.cooldowns[name][type] = cd + 1
    true
  end

  def act_desc(duel, act)
    return '입력 없음 (턴 상실)' if act.nil?

    case act[:type]
    when '관찰' then '관찰'
    when '순간이동' then "순간이동 #{act[:from]} → #{act[:to]}"
    else
      if act[:target]
        extra = act[:cost] ? " (소모 #{act[:cost]})" : ''
        "#{act[:type]} → #{lab(duel, act[:target])}#{extra}"
      elsif act[:reset_skill]
        "#{act[:type]} → #{act[:targets].map { |t| lab(duel, t) }.join(', ')}의 [#{act[:reset_skill]}]"
      elsif act[:targets] && !act[:targets].empty?
        "#{act[:type]} → #{act[:targets].map { |t| lab(duel, t) }.join(', ')}"
      else
        act[:type]
      end
    end
  end

  def settle_duel(duel, view_sheet, scout_sheet)
    size = duel.team_a.size
    round_no = duel.round
    ctx = duel_ctx(duel)
    ctx[:potion_used] = []
    start_hp = duel.hp.dup
    alive = alive_members(duel)
    acted = alive.select { |n| duel.actions.key?(n) }
    log = []

    summary = alive.map { |n| "· #{lab(duel, n)}: #{act_desc(duel, duel.actions[n])}" }

    atk_bonus = Hash.new(0)
    dur_bonus = Hash.new(0)
    tec_bonus = Hash.new(0)
    luck_bonus = Hash.new(0)
    agi_bonus = Hash.new(0)
    defended = Hash.new(1.0)
    members(duel).each do |n|
      atk_bonus[n] += buff_bonus(ctx, n, :atk)
      dur_bonus[n] += buff_bonus(ctx, n, :dur)
      tec_bonus[n] += buff_bonus(ctx, n, :tec)
      luck_bonus[n] += buff_bonus(ctx, n, :luck)
      agi_bonus[n] += buff_bonus(ctx, n, :agi)
    end

    ctx[:round] = round_no

    # 기숙사 패시브 (그리핀도르1, 래번클로1은 3-3 이후)
    passive_lines = []
    alive.each do |n|
      s = stat_of(duel, n)
      dn = lab(duel, n)
      hp = duel.hp[n].to_i
      max = max_hp_of(duel, n, start_hp)
      case s[:house].to_s.strip
      when '그리핀도르'
        if s[:passive].to_s == '2' && max > 0 && hp.to_f < max * 0.4
          b = (s[:atk].to_i * 0.5).ceil
          atk_bonus[n] += b
          passive_lines << "#{dn}: [그리핀도르] 건강 40% 미만 — 마법능력 +#{b}"
        end
      when '슬리데린'
        if s[:passive].to_s == '1' && round_no > 1 && !ctx[:prev_took_damage][n]
          b = (s[:atk].to_i * 0.5).ceil
          atk_bonus[n] += b
          passive_lines << "#{dn}: [슬리데린] 이전 라운드 무피해 — 마법능력 +#{b}"
        end
        if s[:passive].to_s == '2' && ctx[:slytherin_luck][n].to_i > 0
          luck_bonus[n] += ctx[:slytherin_luck][n]
          passive_lines << "#{dn}: [슬리데린] 관찰 보너스 — 행운 +#{ctx[:slytherin_luck][n]}"
        end
      when '래번클로'
        if s[:passive].to_s == '2'
          prev_cat = BattleSkills.category(ctx[:prev_action][n])
          cur_cat = BattleSkills.category(duel.actions[n] && duel.actions[n][:type])
          if prev_cat && cur_cat && prev_cat != cur_cat
            tec_bonus[n] += 10
            passive_lines << "#{dn}: [래번클로] 행동 분류 변경 — 기술 +10"
          end
        end
      when '후플푸프'
        if s[:passive].to_s == '1' && ctx[:prev_took_damage][n]
          b = (s[:dur].to_i * 0.5).ceil
          dur_bonus[n] += b
          passive_lines << "#{dn}: [후플푸프] 이전 라운드 피격 — 내구도 +#{b}"
        end
      end
    end
    unless passive_lines.empty?
      log << '[기숙사 패시브]'
      log.concat(passive_lines)
    end

    in_range = ->(from, to, range) { BattleGrid.in_range?(duel.positions[from], duel.positions[to], range) }
    allies_in_range = lambda do |n, range|
      alive_members(duel).select { |r| team_of(duel, r) == team_of(duel, n) && in_range.call(n, r, range) }
    end

    # 1) 지원
    acted.each do |n|
      act = duel.actions[n]
      skill = BattleSkills.get(act[:type])
      next unless skill && BattleSkills.support?(act[:type])

      s = stat_of(duel, n)
      dname = lab(duel, n)
      next unless duel_gate!(duel, ctx, log, n, act[:type], skill, dname)

      case skill[:kind]
      when :heal
        healed = []
        act[:targets].each do |t|
          next unless duel.hp[t].to_i > 0

          heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
          before = duel.hp[t].to_i
          duel.hp[t] = [before + heal, max_hp_of(duel, t, start_hp)].min
          healed << "#{lab(duel, t)} 건강 +#{duel.hp[t] - before}"
        end
        log << "#{dname}의 #{act[:type]} → #{healed.join(', ')}" if healed.any?
      when :heal_area
        healed = []
        allies_in_range.call(n, skill[:range]).each do |r|
          heal = (s[:atk].to_i * skill[:ratio].to_f).ceil
          before = duel.hp[r].to_i
          duel.hp[r] = [before + heal, max_hp_of(duel, r, start_hp)].min
          healed << "#{lab(duel, r)} +#{duel.hp[r] - before}"
        end
        log << "#{dname}의 구원 → #{healed.join(', ')}" if healed.any?
      when :heal_fixed
        t = act[:targets].first
        if t && duel.hp[t].to_i > 0
          before = duel.hp[t].to_i
          duel.hp[t] = [before + skill[:value].to_i, max_hp_of(duel, t, start_hp)].min
          ctx[:potion_used] << { user: n, skill: act[:type] } if BattleItems.potion?(act[:type])
          log << "#{dname}의 #{act[:type]} → #{lab(duel, t)} 건강 +#{duel.hp[t] - before}"
        else
          log << "#{dname}의 #{act[:type]} → 대상이 행동불능이라 효과가 없습니다."
        end
      when :atk_buff_area
        amount = ((s[:atk].to_i + atk_bonus[n]) * skill[:ratio].to_f).ceil
        affected = []
        allies_in_range.call(n, skill[:range]).each do |r|
          existing = buff_bonus(ctx, r, :atk)
          ctx[:buffs][r].reject! { |b| b[:stat] == :atk }
          atk_bonus[r] += (amount - existing)
          ctx[:buffs][r] << { stat: :atk, value: amount, turns: 1 }
          affected << lab(duel, r)
        end
        log << "#{dname}의 강화 → #{affected.join(', ')} 마법능력 +#{amount}" if affected.any?
      when :shield
        applied = act[:targets].map do |t|
          ctx[:shields][t] += skill[:value].to_i
          lab(duel, t)
        end
        log << "#{dname}의 보호 → #{applied.join(', ')} 보호막 +#{skill[:value]}" if applied.any?
      when :sure_hit
        applied = act[:targets].map do |t|
          ctx[:sure_hit][t] = true
          lab(duel, t)
        end
        log << "#{dname}의 백발백중 → #{applied.join(', ')}의 다음 공격 필중/크리티컬" if applied.any?
      when :luck_buff
        applied = act[:targets].map do |t|
          luck_bonus[t] += skill[:value].to_i
          ctx[:buffs][t] << { stat: :luck, value: skill[:value].to_i, turns: skill[:turns].to_i }
          lab(duel, t)
        end
        log << "#{dname}의 응원 → #{applied.join(', ')} 행운 +#{skill[:value]} (#{skill[:turns]}턴)" if applied.any?
      when :cooldown_reset
        act[:targets].each { |t| duel.cooldowns[t].delete(act[:reset_skill]) }
        log << "#{dname}의 즉발 → #{act[:targets].map { |t| lab(duel, t) }.join(', ')}의 [#{act[:reset_skill]}] 쿨타임 초기화"
      end
    end

    # 2) 방어
    acted.each do |n|
      act = duel.actions[n]
      skill = BattleSkills.get(act[:type])
      next unless skill && BattleSkills.defense?(act[:type])

      s = stat_of(duel, n)
      dname = lab(duel, n)
      next unless duel_gate!(duel, ctx, log, n, act[:type], skill, dname)

      case skill[:kind]
      when :dur_guard
        t = act[:targets].first || n
        defended[t] *= skill[:ratio].to_f
        log << "#{dname}의 방어 → #{lab(duel, t)} 내구도 #{skill[:ratio]}배"
      when :agi_buff_self
        agi_bonus[n] += skill[:value].to_i
        log << "#{dname}의 회피 → 민첩 +#{skill[:value]}"
      when :dur_buff_area
        amount = ((s[:dur].to_i + dur_bonus[n]) * skill[:ratio].to_f).ceil
        affected = allies_in_range.call(n, skill[:range]).map do |r|
          dur_bonus[r] += amount
          lab(duel, r)
        end
        log << "#{dname}의 철벽 → #{affected.join(', ')} 내구도 +#{amount}" if affected.any?
      when :agi_buff_area
        affected = allies_in_range.call(n, skill[:range]).map do |r|
          agi_bonus[r] += skill[:value].to_i
          lab(duel, r)
        end
        log << "#{dname}의 주의분산 → #{affected.join(', ')} 민첩 +#{skill[:value]}" if affected.any?
      end
    end

    # 3) 공격 (동시 정산: 피해를 모아 두었다가 한꺼번에 반영한다)
    damage = Hash.new(0)
    acted.each do |n|
      act = duel.actions[n]
      skill = BattleSkills.get(act[:type])
      next unless skill && BattleSkills.attack?(act[:type])

      s = stat_of(duel, n)
      an = lab(duel, n)
      next unless duel_gate!(duel, ctx, log, n, act[:type], skill, an)

      t = act[:target]
      ts = stat_of(duel, t)
      tn = lab(duel, t)
      sure = ctx[:sure_hit].delete(n)
      sacrifice = skill[:kind] == :sacrifice_attack
      eff_atk = s[:atk].to_i + atk_bonus[n]

      log << ''
      log << "#{an}의 #{act[:type]} → #{tn}"

      if sacrifice
        cost = act[:cost].to_i
        cost = 10 if cost <= 0
        cost = [[cost, duel.hp[n].to_i - 1].min, 0].max
        hp_before = duel.hp[n].to_i
        duel.hp[n] -= cost
        bonus = (cost * 1.5).ceil
        eff_atk += bonus
        log << "#{an} 고육지책 건강 #{hp_before} → #{duel.hp[n]} (소모 #{cost}) / 마법능력 +#{bonus}"
      end

      if sure || sacrifice
        log << '명중: 자동 명중'
      else
        hit = BattleCalculator.hit_detail(s[:tec].to_i + tec_bonus[n])
        log << "명중 #{hit[:rate]}% → #{hit[:roll]} (#{hit[:success] ? '명중' : '빗나감'})"
        unless hit[:success]
          log << "#{an}의 #{act[:type]} 빗나감"
          next
        end

        ev = BattleCalculator.evade_detail(ts[:agi].to_i + agi_bonus[t])
        log << "회피 #{ev[:rate]}% → #{ev[:roll]} (#{ev[:success] ? '회피' : '피격'})" if ev && ev[:roll]
        if ev && ev[:success]
          log << "#{tn} 회피 — 피해 없음"
          next
        end
      end

      if sure
        crit = true
        log << '크리티컬: 자동 크리티컬'
      else
        cr = BattleCalculator.critical_detail(s[:luck].to_i + luck_bonus[n])
        crit = cr && cr[:success]
        if cr && cr[:roll]
          log << "크리티컬 #{cr[:rate]}% → #{cr[:roll]} (#{crit ? '크리티컬' : '일반'})"
        else
          log << "크리티컬 #{cr ? cr[:rate] : 0}% → 판정 없음 (일반)"
        end
      end

      mult = skill[:multiplier].to_f
      scaled = (eff_atk * mult).ceil
      power = crit ? scaled * 2 : scaled
      total_dur = ts[:dur].to_i + dur_bonus[t]
      eff_dur = (total_dur * defended[t]).to_i
      dmg = BattleCalculator.calc_damage(power, eff_dur)
      log << "공격력 #{eff_atk} ×#{mult} = #{scaled}#{crit ? " (크리티컬 ×2 = #{power})" : ''}"
      log << "내구도 #{total_dur}#{defended[t] == 1.0 ? '' : " (방어 ×#{defended[t]} = #{eff_dur})"}"
      if ctx[:shields][t].to_i > 0 && dmg > 0
        blocked = [ctx[:shields][t], dmg].min
        ctx[:shields][t] -= blocked
        dmg -= blocked
        log << "#{tn} 보호막 #{blocked} 차단"
      end
      damage[t] += dmg
      log << "실질 피해 #{dmg}"
    end

    # 4) 체력 반영 (후플푸프2: 전투당 1회, 0 이하가 되면 건강 1로 생존)
    damage.each do |t, d|
      after = duel.hp[t].to_i - d
      ts = stat_of(duel, t)
      if after <= 0 && d > 0 && ts[:house].to_s.strip == '후플푸프' && ts[:passive].to_s == '2' && !ctx[:guard_used][t]
        ctx[:guard_used][t] = true
        after = 1
        log << "#{lab(duel, t)}: [후플푸프] 건강 0 이하 방지 — 건강 1로 생존 (전투 중 1회)"
      end
      duel.hp[t] = [after, 0].max
    end
    log << ''
    members(duel).each do |n|
      next if start_hp[n] == duel.hp[n]

      log << "#{lab(duel, n)} 건강 #{start_hp[n]} → #{duel.hp[n]}"
    end

    # 5-0) 다음 라운드 패시브용 기록: 이번 라운드 피격 여부, 행동, 슬리데린2 누적
    ctx[:prev_took_damage] = damage.select { |_t, d| d > 0 }.keys.each_with_object({}) { |t, h| h[t] = true }
    members(duel).each { |n| ctx[:prev_action][n] = duel.actions[n] && duel.actions[n][:type] }
    alive.each do |n|
      s = stat_of(duel, n)
      next unless s[:house].to_s.strip == '슬리데린' && s[:passive].to_s == '2'

      act = duel.actions[n]
      ctx[:slytherin_luck][n] += 10 if act.nil? || act[:type] == '관찰'
    end

    # 5) 쿨타임과 버프 정리 (쿨타임은 사용 라운드에 N+1을 넣고 라운드 끝에 1을 뺀다)
    duel.cooldowns.each_value do |h|
      h.keys.each do |k|
        h[k] = [h[k].to_i - 1, 0].max
        h.delete(k) if h[k] <= 0
      end
    end
    ctx[:buffs].each_value do |buffs|
      buffs.each { |b| b[:turns] = b[:turns].to_i - 1 if b[:turns] }
      buffs.reject! { |b| b[:turns] && b[:turns] <= 0 }
    end
    ctx[:shields].clear unless SHIELDS_PERSIST

    # 6) 체력을 시트에 쓰고, 쓰러진 참가자는 전투불능 표시, 사용한 물약은 소지품에서 차감
    saved =
      begin
        view_sheet.update_runner_state(members(duel).map { |n| { name: n, hp: duel.hp[n].to_i } })
      rescue => e
        puts "[결투] 체력 시트 반영 오류: #{e.class}: #{e.message}"
        false
      end
    members(duel).each do |n|
      next unless start_hp[n].to_i > 0 && duel.hp[n].to_i <= 0

      begin
        ScoutDirections.mark_incapacitated!(scout_sheet, n) if scout_sheet && defined?(ScoutDirections)
      rescue => e
        puts "[결투] 전투불능 표시 오류 @#{n}: #{e.class}: #{e.message}"
      end
    end
    begin
      BattleItems.consume_all!(ctx) if defined?(BattleItems)
    rescue => e
      puts "[결투] 물약 차감 오류: #{e.class}: #{e.message}"
    end

    # 7) 승패와 무응답
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
end
