# core/battle_engine.rb

require_relative 'battle_state'
require_relative '../battle_calculator_v3'
require_relative '../skill_list'

class BattleEngine
  TEAM_SIZE  = 6   # 6:6
  MAX_ROUNDS = 6   # 성장 후 기준 (0차는 3라운드)
  MAX_MOVE   = 5   # 최대 이동 칸

  # 정산 순서: 지원 → 이동 → 공격
  ACTION_ORDER = %i[support move attack].freeze

  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager   = sheet_manager
  end

  # ─────────────────────────────────────────────────────
  # 전투 개시
  # ─────────────────────────────────────────────────────
  def start_battle(team1, team2, reply_status, phase_zero: false)
    max_rounds = phase_zero ? 3 : MAX_ROUNDS

    battle_id = "battle_#{Time.now.to_i}_#{rand(9999)}"

    state = {
      type:          "team",
      team1:         team1,
      team2:         team2,
      round:         1,
      max_rounds:    max_rounds,
      turn:          1,           # 1=선공팀 행동, 2=후공팀 행동
      phase:         :omen,       # 전조
      pending:       {},          # { uid => { action:, target:, skill: } }
      buffs:         {},          # { uid => { shield:, def_up:, atk_up:, evasion_up:, protected_by: } }
      ap:            {},          # { uid => 행동력 }
      dead:          [],          # 사망자 목록
      death_count:   Hash.new(0), # { uid => 사망횟수 }
      reply_status:  reply_status,
      start_time:    Time.now
    }

    # 행동력 초기화
    (team1 + team2).each { |uid| state[:ap][uid] = BattleCalculator::INITIAL_AP }

    BattleState.set(battle_id, state)

    msg  = "━━━━━━━━━━━━━━━━━━\n"
    msg += "마스레이드 시작 (#{max_rounds}라운드)\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "팀1(선공): " + team_names(team1) + "\n"
    msg += "팀2(후공): " + team_names(team2) + "\n"
    msg += "\n[전조] 적의 위치가 공개됩니다.\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "라운드 1 / 1턴(선공팀 행동 페이즈)\n"
    msg += build_ap_status(team1 + team2, state)
    msg += "\n행동력 소모: 이동 1칸=1, 스킬마다 상이\n"
    msg += "행동 선언: [커맨드/스킬명/@타겟]"

    reply_to(reply_status, msg)
  end

  # ─────────────────────────────────────────────────────
  # 행동 선언 (구글 시트에서 수집 후 일괄 정산 호출)
  # ─────────────────────────────────────────────────────
  def declare_action(user_id, skill_name, target_id, reply_status)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state     = BattleState.get(battle_id)
    unless state
      reply_to(reply_status, "전투 중이 아닙니다.")
      return
    end

    user = @sheet_manager.find_user(user_id)
    unless user
      reply_to(reply_status, "사용자 정보를 찾을 수 없습니다.")
      return
    end

    skill = SkillList.get(skill_name)
    unless skill
      reply_to(reply_status, "존재하지 않는 스킬입니다: #{skill_name}")
      return
    end

    # 행동력 확인
    ap_cost = SkillList.ap_cost(skill_name)
    current_ap = state[:ap][user_id] || 0
    if current_ap < ap_cost
      reply_to(reply_status, "행동력이 부족합니다. (현재 #{current_ap} / 필요 #{ap_cost})")
      return
    end

    # 대기 페이즈 스킬 제한
    current_team = state[:team1].include?(user_id) ? :team1 : :team2
    active_team  = state[:turn] == 1 ? :team1 : :team2
    is_standby   = current_team != active_team

    if is_standby && skill[:category] != :standby
      reply_to(reply_status, "대기 페이즈에는 [분류:대기] 스킬만 사용할 수 있습니다.")
      return
    end
    if !is_standby && skill[:category] == :standby
      reply_to(reply_status, "[분류:대기] 스킬은 대기 페이즈에만 사용할 수 있습니다.")
      return
    end

    state[:pending][user_id] = { skill: skill_name, target: target_id }
    state[:ap][user_id] = current_ap - ap_cost
    BattleState.update(battle_id, state)

    reply_to(reply_status, "#{user["이름"]}: #{skill_name} 선언 완료 (행동력 #{current_ap}→#{state[:ap][user_id]})")
  end

  # ─────────────────────────────────────────────────────
  # 이동 선언
  # ─────────────────────────────────────────────────────
  def declare_move(user_id, direction, steps, reply_status)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state     = BattleState.get(battle_id)
    unless state
      reply_to(reply_status, "전투 중이 아닙니다.")
      return
    end

    steps = [[steps.to_i, 1].max, MAX_MOVE].min
    ap_cost = steps

    current_ap = state[:ap][user_id] || 0
    if current_ap < ap_cost
      reply_to(reply_status, "행동력이 부족합니다. (이동 #{steps}칸 = #{ap_cost} / 현재 #{current_ap})")
      return
    end

    # 대기 페이즈에는 이동 불가
    current_team = state[:team1].include?(user_id) ? :team1 : :team2
    active_team  = state[:turn] == 1 ? :team1 : :team2
    if current_team != active_team
      reply_to(reply_status, "대기 페이즈에는 이동할 수 없습니다.")
      return
    end

    state[:pending][user_id] ||= {}
    state[:pending][user_id][:move] = { direction: direction, steps: steps }
    state[:ap][user_id] = current_ap - ap_cost
    BattleState.update(battle_id, state)

    user = @sheet_manager.find_user(user_id)
    reply_to(reply_status, "#{user["이름"]}: #{direction} #{steps}칸 이동 선언 (행동력 -#{ap_cost})")
  end

  # ─────────────────────────────────────────────────────
  # 턴 정산 (GM 호출 또는 전원 선언 완료 시)
  # ─────────────────────────────────────────────────────
  def resolve_turn(battle_id, reply_status)
    state = BattleState.get(battle_id)
    unless state
      reply_to(reply_status, "전투를 찾을 수 없습니다.")
      return
    end

    msg = "━━━━━━━━━━━━━━━━━━\n"
    msg += "라운드 #{state[:round]} / #{state[:turn] == 1 ? "1턴(선공)" : "2턴(후공)"} 정산\n"
    msg += "━━━━━━━━━━━━━━━━━━\n\n"

    active_team  = state[:turn] == 1 ? state[:team1] : state[:team2]

    # 정산 순서: 지원 → 이동 → 공격
    ACTION_ORDER.each do |phase|
      active_team.each do |uid|
        action = state[:pending][uid]
        next unless action

        case phase
        when :support
          next unless action[:skill] && SkillList.category(action[:skill]) == :support
          msg += resolve_skill(uid, action[:skill], action[:target], battle_id, state)
        when :move
          next unless action[:move]
          msg += "#{user_name(uid)} 이동: #{action[:move][:direction]} #{action[:move][:steps]}칸\n"
        when :attack
          next unless action[:skill] && SkillList.category(action[:skill]) == :attack
          msg += resolve_skill(uid, action[:skill], action[:target], battle_id, state)
        end
      end

      # 대기 페이즈 팀 대기 스킬 정산
      if phase == :support
        standby_team = state[:turn] == 1 ? state[:team2] : state[:team1]
        standby_team.each do |uid|
          action = state[:pending][uid]
          next unless action && action[:skill]
          next unless SkillList.category(action[:skill]) == :standby
          msg += resolve_standby(uid, action[:skill], battle_id, state)
        end
      end
    end

    # 행동력 회복 (아군 행동 페이즈마다 +2)
    active_team.each do |uid|
      state[:ap][uid] = [((state[:ap][uid] || 0) + BattleCalculator::AP_REGEN), 10].min
    end

    state[:pending] = {}

    # 턴 전환
    if state[:turn] == 1
      state[:turn] = 2
      msg += "\n━━━━━━━━━━━━━━━━━━\n"
      msg += "2턴(후공팀 행동 페이즈) 시작\n"
    else
      state[:turn]  = 1
      state[:round] += 1

      # 라운드 종료 - 승패 확인
      if check_battle_end(battle_id, state, msg)
        BattleState.update(battle_id, state)
        return
      end

      if state[:round] > state[:max_rounds]
        msg += "\n전투 종료 (라운드 종료)\n"
        msg += build_result(state)
        finalize_battle(battle_id, state, msg)
        return
      end

      msg += "\n━━━━━━━━━━━━━━━━━━\n"
      msg += "라운드 #{state[:round]} 시작\n"
      # 새 라운드 1턴: 행동력 5 지급
      (state[:team1] + state[:team2]).each { |uid| state[:ap][uid] = BattleCalculator::INITIAL_AP }
    end

    msg += build_ap_status(state[:team1] + state[:team2], state)
    BattleState.update(battle_id, state)
    reply_to(reply_status, msg)
  end

  # ─────────────────────────────────────────────────────
  # 전투 강제 종료 (GM)
  # ─────────────────────────────────────────────────────
  def end_battle(battle_id, reply_status)
    state = BattleState.get(battle_id)
    unless state
      reply_to(reply_status, "전투를 찾을 수 없습니다.")
      return
    end
    msg = "GM에 의해 전투 종료\n" + build_result(state)
    finalize_battle(battle_id, state, msg)
  end

  private

  # ─────────────────────────────────────────────────────
  # 스킬 정산
  # ─────────────────────────────────────────────────────
  def resolve_skill(user_id, skill_name, target_id, battle_id, state)
    attacker = @sheet_manager.find_user(user_id)
    skill    = SkillList.get(skill_name)
    msg      = ""

    case skill_name
    when "기본공격", "저격", "강타", "관통", "폭격", "생사결단"
      targets = skill_name == "폭격" ? pick_enemies(user_id, state, 3) : [target_id]

      targets.each do |tid|
        defender = @sheet_manager.find_user(tid)
        next unless defender

        # 명중 판정
        unless BattleCalculator.hit_check(attacker, defender)
          msg += "#{user_name(user_id)} → #{user_name(tid)}: 회피! (명중률 #{BattleCalculator.hit_rate(attacker, defender)}%)\n"
          next
        end

        # 반격태세 확인
        counter_pending = state.dig(:pending, tid, :skill) == "반격태세"

        # 공격력 계산
        raw  = BattleCalculator.attack_power(attacker)
        raw  = (raw * 1.5).to_i if skill_name == "강타"
        raw  = (raw * 2.5).to_i if skill_name == "생사결단"
        is_crit = BattleCalculator.critical_check(attacker)
        raw  = (raw * 1.5).to_i if is_crit

        ignore_def = skill[:ignore_defense] || false
        result     = BattleCalculator.final_damage(raw, defender, attacker, ignore_defense: ignore_def)

        # 보호막 처리
        shield = state.dig(:buffs, tid, :shield) || 0
        actual_dmg = result[:total]
        if shield > 0
          absorbed   = [shield, actual_dmg].min
          actual_dmg -= absorbed
          state[:buffs][tid][:shield] = shield - absorbed
          msg += "#{user_name(tid)} 보호막 흡수: #{absorbed}\n"
        end

        # HP 적용
        apply_damage(tid, actual_dmg, state)

        msg += "#{user_name(user_id)} [#{skill_name}] → #{user_name(tid)}\n"
        msg += "  공격력 #{raw}#{is_crit ? " [크리티컬]" : ""}"
        msg += " / 방어력 #{ignore_def ? "무시" : BattleCalculator.defense_power(defender)}"
        msg += " / 기본피해 #{result[:base]}"
        msg += " / 추가피해 #{result[:bonus]}" if result[:bonus] > 0
        msg += " / 최종 #{actual_dmg}\n"

        # 생사결단 반동
        if skill_name == "생사결단"
          recoil = (result[:total] * 0.3).to_i
          apply_damage(user_id, recoil, state)
          msg += "  반동 피해: #{recoil}\n"
        end

        # 반격
        if counter_pending && !state[:dead].include?(user_id)
          counter_raw    = BattleCalculator.attack_power(defender)
          counter_result = BattleCalculator.final_damage(counter_raw, attacker, defender)
          apply_damage(user_id, counter_result[:total], state)
          msg += "  #{user_name(tid)} 반격: #{counter_result[:total]}\n"
        end

        msg += hp_line(tid)
      end

    when "회복"
      target = @sheet_manager.find_user(target_id)
      return "#{user_name(user_id)}: 대상 없음\n" unless target
      amount  = BattleCalculator.heal_single(attacker)
      heal_hp(target_id, amount, state)
      msg += "#{user_name(user_id)} [회복] → #{user_name(target_id)}: +#{amount}HP\n" + hp_line(target_id)

    when "다중회복"
      amount  = BattleCalculator.heal_multi(attacker)
      targets = pick_allies(user_id, state, 3)
      targets.each do |tid|
        heal_hp(tid, amount, state)
        msg += "#{user_name(user_id)} [다중회복] → #{user_name(tid)}: +#{amount}HP\n"
      end

    when "천사의 노래"
      targets = pick_allies(user_id, state, 3)
      targets.each do |tid|
        u      = @sheet_manager.find_user(tid)
        max_hp = BattleCalculator.max_hp(u)
        cur_hp = (u["HP"] || max_hp).to_i
        heal   = max_hp - cur_hp
        heal_hp(tid, heal, state) if heal > 0
        msg += "#{user_name(user_id)} [천사의 노래] → #{user_name(tid)}: 전체 회복\n"
      end

    when "보호"
      target = @sheet_manager.find_user(target_id)
      return "#{user_name(user_id)}: 대상 없음\n" unless target
      amount = BattleCalculator.shield_amount(attacker)
      state[:buffs][target_id] ||= {}
      state[:buffs][target_id][:shield] = amount
      msg += "#{user_name(user_id)} [보호] → #{user_name(target_id)}: 보호막 #{amount}\n"

    when "방어지원"
      targets = pick_allies(user_id, state, 3)
      targets.each do |tid|
        state[:buffs][tid] ||= {}
        state[:buffs][tid][:def_up] = 15
      end
      msg += "#{user_name(user_id)} [방어지원]: 아군 3인 방어력 +15\n"

    when "공격지원"
      targets = pick_allies(user_id, state, 3)
      targets.each do |tid|
        state[:buffs][tid] ||= {}
        state[:buffs][tid][:atk_up] = 15
      end
      msg += "#{user_name(user_id)} [공격지원]: 아군 3인 공격력 +15\n"

    when "회피지원"
      targets = pick_allies(user_id, state, 3)
      targets.each do |tid|
        state[:buffs][tid] ||= {}
        state[:buffs][tid][:evasion_up] = 20
      end
      msg += "#{user_name(user_id)} [회피지원]: 아군 3인 회피율 +20%\n"

    when "경호"
      target = @sheet_manager.find_user(target_id)
      return "#{user_name(user_id)}: 대상 없음\n" unless target
      state[:buffs][target_id] ||= {}
      state[:buffs][target_id][:protected_by] = user_id
      msg += "#{user_name(user_id)} [경호] → #{user_name(target_id)}: 다음 피격 대신 받음\n"

    when "행동지원"
      target = @sheet_manager.find_user(target_id)
      return "#{user_name(user_id)}: 대상 없음\n" unless target
      state[:ap][target_id] = [(state[:ap][target_id] || 0) + 2, 10].min
      msg += "#{user_name(user_id)} [행동지원] → #{user_name(target_id)}: 행동력 +2\n"

    when "신의 가호"
      all_allies = allies_of(user_id, state)
      all_allies.each do |tid|
        u       = @sheet_manager.find_user(user_id)
        def_up  = (BattleCalculator.defense_power(u) * 0.5).to_i
        state[:buffs][tid] ||= {}
        state[:buffs][tid][:def_up] = [(state.dig(:buffs, tid, :def_up) || 0) + def_up, 999].min
      end
      msg += "#{user_name(user_id)} [신의 가호]: 아군 전원 방어력 상승\n"

    when "속박의 낙인"
      enemies_of(user_id, state).each do |tid|
        state[:buffs][tid] ||= {}
        state[:buffs][tid][:bound] = true
      end
      msg += "#{user_name(user_id)} [속박의 낙인]: 적군 전원 행동 봉쇄\n"

    when "소생술"
      dead_ally = state[:dead].find { |uid| allies_of(user_id, state).include?(uid) }
      if dead_ally
        state[:dead].delete(dead_ally)
        state[:ap][dead_ally] = 5
        u = @sheet_manager.find_user(dead_ally)
        @sheet_manager.update_user(dead_ally, { "HP" => BattleCalculator.max_hp(u) })
        msg += "#{user_name(user_id)} [소생술]: #{user_name(dead_ally)} 부활!\n"
      else
        msg += "#{user_name(user_id)} [소생술]: 부활 대상 없음\n"
      end

    when "불굴의 의지"
      targets = pick_allies(user_id, state, 3)
      targets.each do |tid|
        state[:buffs][tid] ||= {}
        state[:buffs][tid][:indomitable] = true
        state[:buffs][tid][:protected_by] = user_id
      end
      msg += "#{user_name(user_id)} [불굴의 의지]: 아군 3인 보호 + 체력 1 이하 불가\n"
    end

    msg
  end

  def resolve_standby(user_id, skill_name, battle_id, state)
    case skill_name
    when "방어태세"
      state[:buffs][user_id] ||= {}
      state[:buffs][user_id][:defense_stance] = true
      "#{user_name(user_id)} [방어태세]: 피격 대미지 20% 감소\n"
    when "회피"
      state[:buffs][user_id] ||= {}
      state[:buffs][user_id][:evasion_up] = (state.dig(:buffs, user_id, :evasion_up) || 0) + 50
      "#{user_name(user_id)} [회피]: 회피율 +50%\n"
    when "반격태세"
      "#{user_name(user_id)} [반격태세]: 다음 피격 시 반격 준비\n"
    else
      ""
    end
  end

  def apply_damage(user_id, damage, state)
    return if damage <= 0
    u      = @sheet_manager.find_user(user_id)
    max_hp = BattleCalculator.max_hp(u)
    cur_hp = (u["HP"] || max_hp).to_i

    # 방어태세 20% 감소
    if state.dig(:buffs, user_id, :defense_stance)
      damage = (damage * 0.8).to_i
    end

    # 불굴의 의지: 체력 1 이하 불가
    indomitable = state.dig(:buffs, user_id, :indomitable)

    new_hp = cur_hp - damage
    if indomitable && new_hp < 1
      new_hp = 1
    end
    new_hp = [new_hp, 0].max

    @sheet_manager.update_user(user_id, { "HP" => new_hp })

    if new_hp <= 0 && !state[:dead].include?(user_id)
      state[:dead] << user_id
      state[:death_count][user_id] += 1
    end
  end

  def heal_hp(user_id, amount, state)
    u      = @sheet_manager.find_user(user_id)
    max_hp = BattleCalculator.max_hp(u)
    cur_hp = (u["HP"] || max_hp).to_i
    new_hp = [cur_hp + amount, max_hp].min
    @sheet_manager.update_user(user_id, { "HP" => new_hp })
  end

  def hp_line(user_id)
    u      = @sheet_manager.find_user(user_id)
    return "" unless u
    max_hp = BattleCalculator.max_hp(u)
    cur_hp = (u["HP"] || max_hp).to_i
    bar    = BattleCalculator.hp_bar(cur_hp, max_hp)
    "  #{u["이름"]}: #{bar} #{cur_hp}/#{max_hp}\n"
  end

  def build_ap_status(participants, state)
    msg = "\n행동력 현황\n"
    participants.each do |uid|
      u  = @sheet_manager.find_user(uid)
      ap = state[:ap][uid] || 0
      msg += "  #{u ? u["이름"] : uid}: #{ap}\n"
    end
    msg
  end

  def build_result(state)
    msg  = "━━━━━━━━━━━━━━━━━━\n전투 결과\n━━━━━━━━━━━━━━━━━━\n"
    msg += "사망 횟수:\n"
    (state[:team1] + state[:team2]).each do |uid|
      count = state[:death_count][uid] || 0
      msg  += "  #{user_name(uid)}: #{count}회\n"
    end

    t1_deaths = state[:team1].sum { |uid| state[:death_count][uid] || 0 }
    t2_deaths = state[:team2].sum { |uid| state[:death_count][uid] || 0 }

    if t1_deaths < t2_deaths
      msg += "팀1 승리 (사망 #{t1_deaths} < #{t2_deaths})\n"
    elsif t2_deaths < t1_deaths
      msg += "팀2 승리 (사망 #{t2_deaths} < #{t1_deaths})\n"
    else
      # 1회 이상 사망 인원 수
      t1_dead_count = state[:team1].count { |uid| (state[:death_count][uid] || 0) >= 1 }
      t2_dead_count = state[:team2].count { |uid| (state[:death_count][uid] || 0) >= 1 }
      if t1_dead_count < t2_dead_count
        msg += "팀1 승리 (사망 인원 #{t1_dead_count} < #{t2_dead_count})\n"
      elsif t2_dead_count < t1_dead_count
        msg += "팀2 승리 (사망 인원 #{t2_dead_count} < #{t1_dead_count})\n"
      else
        # 최종 체력 합산
        t1_hp = state[:team1].sum { |uid| u = @sheet_manager.find_user(uid); u ? (u["HP"] || 0).to_i : 0 }
        t2_hp = state[:team2].sum { |uid| u = @sheet_manager.find_user(uid); u ? (u["HP"] || 0).to_i : 0 }
        if t1_hp > t2_hp
          msg += "팀1 승리 (잔여 체력 #{t1_hp} > #{t2_hp})\n"
        elsif t2_hp > t1_hp
          msg += "팀2 승리 (잔여 체력 #{t2_hp} > #{t1_hp})\n"
        else
          msg += "무승부\n"
        end
      end
    end
    msg
  end

  def check_battle_end(battle_id, state, msg)
    t1_alive = state[:team1].count { |uid| !state[:dead].include?(uid) }
    t2_alive = state[:team2].count { |uid| !state[:dead].include?(uid) }
    if t1_alive == 0 || t2_alive == 0
      result_msg = msg + "\n" + build_result(state)
      finalize_battle(battle_id, state, result_msg)
      return true
    end
    false
  end

  def finalize_battle(battle_id, state, message)
    reply_to(state[:reply_status], message)
    # 전투 종료 직후 HP 자동 회복
    (state[:team1] + state[:team2]).each do |uid|
      u = @sheet_manager.find_user(uid)
      next unless u
      @sheet_manager.update_user(uid, { "HP" => BattleCalculator.max_hp(u) })
    end
    BattleState.clear(battle_id)
  end

  def pick_allies(user_id, state, count)
    team = allies_of(user_id, state)
    (team - state[:dead]).first(count)
  end

  def pick_enemies(user_id, state, count)
    team = enemies_of(user_id, state)
    (team - state[:dead]).first(count)
  end

  def allies_of(user_id, state)
    state[:team1].include?(user_id) ? state[:team1] : state[:team2]
  end

  def enemies_of(user_id, state)
    state[:team1].include?(user_id) ? state[:team2] : state[:team1]
  end

  def user_name(user_id)
    u = @sheet_manager.find_user(user_id)
    u ? (u["이름"] || user_id) : user_id
  end

  def team_names(team)
    team.map { |uid| user_name(uid) }.join(", ")
  end

  def reply_to(status, message)
    return unless status
    @mastodon_client.reply(status, message)
  end
end
