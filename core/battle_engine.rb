require_relative 'battle_state'

class BattleEngine
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager   = sheet_manager
  end

  # 1:1 전투 시작
  def start_1v1(user1_id, user2_id, reply_status)
    # 이미 전투 중인지 확인
    if BattleState.find_by_user(user1_id)
      user1_name = (@sheet_manager.find_user(user1_id) || {})["이름"] || user1_id
      @mastodon_client.reply(reply_status, "#{user1_name}님은 이미 전투 중입니다.")
      return
    end
    
    if BattleState.find_by_user(user2_id)
      user2_name = (@sheet_manager.find_user(user2_id) || {})["이름"] || user2_id
      @mastodon_client.reply(reply_status, "#{user2_name}님은 이미 전투 중입니다.")
      return
    end

    user1 = @sheet_manager.find_user(user1_id)
    user2 = @sheet_manager.find_user(user2_id)
    unless user1 && user2
      @mastodon_client.reply(reply_status, "참가자 중 등록되지 않은 사용자가 있습니다.")
      return
    end

    # 민첩성 판정
    agi1 = (user1["민첩성"] || 10).to_i + rand(1..20)
    agi2 = (user2["민첩성"] || 10).to_i + rand(1..20)
    turn_order = agi1 >= agi2 ? [user1_id, user2_id] : [user2_id, user1_id]

    user1_name = user1["이름"] || user1_id
    user2_name = user2["이름"] || user2_id
    first_turn_name = turn_order[0] == user1_id ? user1_name : user2_name
    first_agi = agi1 >= agi2 ? agi1 : agi2
    
    message = "━━━━━━━━━━━━━━━━━━\n"
    message += "전투 시작: #{user1_name} vs #{user2_name}\n"
    message += "선공: #{first_turn_name} (민첩 #{first_agi})\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "제한시간: 1인당 4분, 전체 1시간\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "#{first_turn_name}의 차례\n"
    message += "[공격] [방어] [반격] [물약사용/크기]"

    result = @mastodon_client.reply_with_mentions(reply_status, message, [user1_id, user2_id])
    
    battle_id = BattleState.create([user1_id, user2_id], {
      type: "1v1",
      participants: [user1_id, user2_id],
      turn_order: turn_order,
      current_turn: turn_order[0],
      round: 1,
      guarded: {},
      counter: {},
      reply_status: result || reply_status
    })
    
    puts "[전투] 1:1 전투 생성: #{battle_id}"
  end

  # 2:2 전투 시작
  def start_2v2(user1_id, user2_id, user3_id, user4_id, reply_status)
    ids = [user1_id, user2_id, user3_id, user4_id]
    
    # 이미 전투 중인지 확인
    ids.each do |id|
      if BattleState.find_by_user(id)
        user_name = (@sheet_manager.find_user(id) || {})["이름"] || id
        @mastodon_client.reply(reply_status, "#{user_name}님은 이미 전투 중입니다.")
        return
      end
    end
    
    users = ids.map { |id| @sheet_manager.find_user(id) }
    if users.any?(&:nil?)
      @mastodon_client.reply(reply_status, "참가자 중 등록되지 않은 사용자가 있습니다.")
      return
    end

    # 팀 구성: A,B vs C,D
    team1 = [user1_id, user2_id]
    team2 = [user3_id, user4_id]

    # 민첩성 판정 (팀별 합산)
    team1_agi = team1.sum { |id| (users[ids.index(id)]["민첩성"] || 10).to_i } + rand(1..20)
    team2_agi = team2.sum { |id| (users[ids.index(id)]["민첩성"] || 10).to_i } + rand(1..20)

    # 선공 팀 결정
    first_team = team1_agi >= team2_agi ? team1 : team2
    second_team = team1_agi >= team2_agi ? team2 : team1
    turn_order = first_team + second_team

    names = ids.map { |id| (users[ids.index(id)]["이름"] || id) }
    
    message = "━━━━━━━━━━━━━━━━━━\n"
    message += "팀전투 시작: #{names[0]}, #{names[1]} vs #{names[2]}, #{names[3]}\n"
    message += "선공: 팀#{team1_agi >= team2_agi ? '1' : '2'} (민첩 #{[team1_agi, team2_agi].max})\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "제한시간: 1인당 4분, 전체 1시간\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "모든 참가자는 행동을 선택하세요!\n"
    message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"

    result = @mastodon_client.reply_with_mentions(reply_status, message, ids)
    
    battle_id = BattleState.create(ids, {
      type: "2v2",
      participants: ids,
      teams: { team1: team1, team2: team2 },
      turn_order: turn_order,
      current_turn: turn_order[0],
      turn_index: 0,
      round: 1,
      actions_queue: [],
      guarded: {},
      counter: {},
      reply_status: result || reply_status
    })
    
    puts "[전투] 2:2 전투 생성: #{battle_id}"
  end

  # 4:4 전투 시작
  def start_4v4(u1, u2, u3, u4, u5, u6, u7, u8, reply_status)
    ids = [u1, u2, u3, u4, u5, u6, u7, u8]
    
    ids.each do |id|
      if BattleState.find_by_user(id)
        user_name = (@sheet_manager.find_user(id) || {})["이름"] || id
        @mastodon_client.reply(reply_status, "#{user_name}님은 이미 전투 중입니다.")
        return
      end
    end
    
    users = ids.map { |id| @sheet_manager.find_user(id) }
    if users.any?(&:nil?)
      @mastodon_client.reply(reply_status, "참가자 중 등록되지 않은 사용자가 있습니다.")
      return
    end

    # 팀 구성
    team1 = [u1, u2, u3, u4]
    team2 = [u5, u6, u7, u8]

    # 민첩성 판정
    team1_agi = team1.sum { |id| (@sheet_manager.find_user(id)["민첩성"] || 10).to_i } + rand(1..20)
    team2_agi = team2.sum { |id| (@sheet_manager.find_user(id)["민첩성"] || 10).to_i } + rand(1..20)

    first_team = team1_agi >= team2_agi ? team1 : team2
    second_team = team1_agi >= team2_agi ? team2 : team1
    turn_order = first_team + second_team

    names = ids.map { |id| (@sheet_manager.find_user(id)["이름"] || id) }
    
    message = "━━━━━━━━━━━━━━━━━━\n"
    message += "대규모전투 시작!\n"
    message += "팀1: #{names[0..3].join(', ')}\n"
    message += "팀2: #{names[4..7].join(', ')}\n"
    message += "선공: 팀#{team1_agi >= team2_agi ? '1' : '2'} (민첩 #{[team1_agi, team2_agi].max})\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "제한시간: 1인당 4분, 전체 1시간\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "모든 참가자는 행동을 선택하세요!\n"
    message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"

    result = @mastodon_client.reply_with_mentions(reply_status, message, ids)
    
    battle_id = BattleState.create(ids, {
      type: "4v4",
      participants: ids,
      teams: { team1: team1, team2: team2 },
      turn_order: turn_order,
      current_turn: turn_order[0],
      turn_index: 0,
      round: 1,
      actions_queue: [],
      guarded: {},
      counter: {},
      reply_status: result || reply_status
    })
    
    puts "[전투] 4:4 전투 생성: #{battle_id}"
  end

  # 공격
  def attack(user_id, target_id = nil)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.post("현재 전투 중이 아닙니다.", visibility: 'public')
      return
    end

    # 시간 초과 체크
    check_and_handle_timeout(battle_id, state)
    
    unless state[:current_turn].to_s == user_id.to_s
      reply_to_battle_thread("당신의 차례가 아닙니다.", battle_id, state)
      return
    end

    if state[:type] == "2v2" || state[:type] == "4v4"
      unless target_id
        reply_to_battle_thread("팀전투에서는 [공격/@타겟] 형식으로 타겟을 지정해야 합니다.", battle_id, state)
        return
      end
      handle_team_action(user_id, :attack, target_id, battle_id, state)
    else
      # 1:1 전투
      target_id ||= find_opponent(user_id, state)
      perform_1v1_attack(user_id, target_id, battle_id, state)
    end
  end

  # 방어
  def defend(user_id)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.post("현재 전투 중이 아닙니다.", visibility: 'public')
      return
    end

    check_and_handle_timeout(battle_id, state)
    
    unless state[:current_turn].to_s == user_id.to_s
      reply_to_battle_thread("당신의 차례가 아닙니다.", battle_id, state)
      return
    end

    if state[:type] == "2v2" || state[:type] == "4v4"
      handle_team_action(user_id, :defend, nil, battle_id, state)
    else
      perform_1v1_defend(user_id, battle_id, state)
    end
  end

  # 아군 방어
  def defend_target(user_id, target_id)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.post("현재 전투 중이 아닙니다.", visibility: 'public')
      return
    end

    check_and_handle_timeout(battle_id, state)
    
    unless state[:current_turn].to_s == user_id.to_s
      reply_to_battle_thread("당신의 차례가 아닙니다.", battle_id, state)
      return
    end

    unless state[:participants].include?(target_id)
      reply_to_battle_thread("전투 참가자가 아닙니다.", battle_id, state)
      return
    end

    if state[:type] == "2v2" || state[:type] == "4v4"
      handle_team_action(user_id, :defend_target, target_id, battle_id, state)
    else
      reply_to_battle_thread("1:1 전투에서는 [방어]만 사용할 수 있습니다.", battle_id, state)
    end
  end

  # 반격
  def counter(user_id)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.post("현재 전투 중이 아닙니다.", visibility: 'public')
      return
    end

    check_and_handle_timeout(battle_id, state)
    
    unless state[:current_turn].to_s == user_id.to_s
      reply_to_battle_thread("당신의 차례가 아닙니다.", battle_id, state)
      return
    end

    if state[:type] == "2v2" || state[:type] == "4v4"
      handle_team_action(user_id, :counter, nil, battle_id, state)
    else
      perform_1v1_counter(user_id, battle_id, state)
    end
  end

  private

  # 체력바 생성
  def create_hp_bar(current_hp, max_hp)
    percentage = [current_hp.to_f / max_hp, 1.0].min
    filled_length = (percentage * 10).round
    
    filled = "█" * filled_length
    empty = "░" * (10 - filled_length)
    
    filled + empty
  end

  # 최대 HP 계산
  def calculate_max_hp(user)
    vitality_stat = (user["체력"] || 0).to_i
    100 + (vitality_stat * 10)
  end

  # 상대방 찾기 (1:1)
  def find_opponent(user_id, state)
    state[:participants].find { |p| p != user_id }
  end

  # 치명타 판정
  def check_critical_hit(luck)
    crit_chance = [luck.to_f / 2, 50].min
    is_crit = rand(1..100) <= crit_chance
    { is_crit: is_crit, chance: crit_chance }
  end

  # 전투 스레드에 응답
  def reply_to_battle_thread(message, battle_id, state)
    return unless state[:reply_status]
    @mastodon_client.reply(state[:reply_status], message)
  end

  # 시간 초과 체크 및 처리
  def check_and_handle_timeout(battle_id, state)
    turn_elapsed = Time.now - state[:last_action_time]
    battle_elapsed = Time.now - state[:start_time]

    # 턴 시간 초과 (4분)
    if turn_elapsed > 240
      auto_defend_timeout(battle_id, state)
      return true
    end

    # 전투 시간 초과 (1시간)
    if battle_elapsed > 3600
      end_battle_by_hp_total(battle_id, state)
      return true
    end

    false
  end

  # 시간 초과 시 자동 방어
  def auto_defend_timeout(battle_id, state)
    user_id = state[:current_turn]
    user = @sheet_manager.find_user(user_id)
    user_name = user ? (user["이름"] || user_id) : user_id

    message = "시간 초과!\n"
    message += "#{user_name}이(가) 4분 내에 행동하지 않아 자동으로 방어합니다.\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    message += "#{user_name}이(가) 방어 태세\n"
    message += "━━━━━━━━━━━━━━━━━━\n"

    state[:guarded] ||= {}
    state[:guarded][user_id] = true

    if state[:type] == "2v2" || state[:type] == "4v4"
      state[:turn_index] += 1
      state[:actions_queue] ||= []
      state[:actions_queue] << { user_id: user_id, action: :defend, target: nil }
      
      if state[:turn_index] >= state[:participants].length
        process_team_round(battle_id, state, message)
      else
        state[:current_turn] = state[:turn_order][state[:turn_index]]
        BattleState.update(battle_id, state)
        
        next_player = @sheet_manager.find_user(state[:current_turn])
        next_player_name = next_player["이름"] || state[:current_turn]
        
        message += "#{next_player_name}의 차례\n"
        message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"
        
        reply_to_battle_thread(message, battle_id, state)
      end
    else
      # 1:1
      state[:current_turn] = state[:turn_order][(state[:turn_order].index(state[:current_turn]) + 1) % state[:turn_order].length]
      BattleState.update(battle_id, state)
      
      next_player = @sheet_manager.find_user(state[:current_turn])
      next_player_name = next_player ? (next_player["이름"] || state[:current_turn]) : state[:current_turn]
      
      message += "#{next_player_name}의 차례\n"
      message += "[공격] [방어] [반격] [물약사용/크기]"
      
      reply_to_battle_thread(message, battle_id, state)
    end
  end

  # 전투 시간 초과 시 체력 총합으로 승부
  def end_battle_by_hp_total(battle_id, state)
    message = "전투 시간 1시간 초과!\n"
    message += "━━━━━━━━━━━━━━━━━━\n"

    if state[:type] == "1v1"
      user1_id = state[:participants][0]
      user2_id = state[:participants][1]
      
      user1 = @sheet_manager.find_user(user1_id)
      user2 = @sheet_manager.find_user(user2_id)
      
      hp1 = (user1["HP"] || 0).to_i
      hp2 = (user2["HP"] || 0).to_i
      
      user1_name = user1["이름"] || user1_id
      user2_name = user2["이름"] || user2_id
      
      message += "체력 비교:\n"
      message += "#{user1_name}: #{hp1}HP\n"
      message += "#{user2_name}: #{hp2}HP\n"
      message += "━━━━━━━━━━━━━━━━━━\n"
      
      if hp1 > hp2
        message += "#{user1_name} 승리! (체력 총합)"
      elsif hp2 > hp1
        message += "#{user2_name} 승리! (체력 총합)"
      else
        message += "무승부!"
      end
    else
      # 팀전투
      team1_hp = state[:teams][:team1].sum do |pid|
        user = @sheet_manager.find_user(pid)
        (user["HP"] || 0).to_i
      end
      
      team2_hp = state[:teams][:team2].sum do |pid|
        user = @sheet_manager.find_user(pid)
        (user["HP"] || 0).to_i
      end
      
      message += "팀별 체력 총합:\n"
      message += "팀1: #{team1_hp}HP\n"
      message += "팀2: #{team2_hp}HP\n"
      message += "━━━━━━━━━━━━━━━━━━\n"
      
      if team1_hp > team2_hp
        message += "팀1 승리! (체력 총합)"
      elsif team2_hp > team1_hp
        message += "팀2 승리! (체력 총합)"
      else
        message += "무승부!"
      end
    end

    reply_to_battle_thread(message, battle_id, state)
    BattleState.clear(battle_id)
  end
  # 1:1 공격 수행
  def perform_1v1_attack(attacker_id, defender_id, battle_id, state)
    attacker = @sheet_manager.find_user(attacker_id)
    defender = @sheet_manager.find_user(defender_id)
    
    result = calculate_attack_result(attacker, attacker_id, defender, defender_id, state)
    
    message = "━━━━━━━━━━━━━━━━━━\n"
    message += "라운드 #{state[:round]} 결과\n"
    message += "━━━━━━━━━━━━━━━━━━\n\n"
    message += result[:message]
    
    # HP 업데이트
    if result[:damage] > 0
      new_hp = [(defender["HP"] || 100).to_i - result[:damage], 0].max
      @sheet_manager.update_user(defender_id, { hp: new_hp })
    end
    
    if result[:counter_damage] > 0
      new_hp = [(attacker["HP"] || 100).to_i - result[:counter_damage], 0].max
      @sheet_manager.update_user(attacker_id, { hp: new_hp })
    end
    
    # 체력 현황
    message += "\n━━━━━━━━━━━━━━━━━━\n"
    message += "체력 현황\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    
    state[:participants].each do |pid|
      user = @sheet_manager.find_user(pid)
      next unless user
      
      user_name = user["이름"] || pid
      current_hp = (user["HP"] || 0).to_i
      max_hp = calculate_max_hp(user)
      hp_bar = create_hp_bar(current_hp, max_hp)
      
      message += "#{user_name}: #{hp_bar} #{current_hp}/#{max_hp}\n"
    end
    message += "━━━━━━━━━━━━━━━━━━\n\n"
    
    # 승부 판정
    attacker_hp = (@sheet_manager.find_user(attacker_id)["HP"] || 0).to_i
    defender_hp = (@sheet_manager.find_user(defender_id)["HP"] || 0).to_i
    
    if defender_hp <= 0
      defender_name = (defender["이름"] || defender_id)
      attacker_name = (attacker["이름"] || attacker_id)
      message += "#{attacker_name} 승리!"
      reply_to_battle_thread(message, battle_id, state)
      BattleState.clear(battle_id)
      return
    elsif attacker_hp <= 0
      defender_name = (defender["이름"] || defender_id)
      attacker_name = (attacker["이름"] || attacker_id)
      message += "#{defender_name} 승리!"
      reply_to_battle_thread(message, battle_id, state)
      BattleState.clear(battle_id)
      return
    end
    
    # 다음 라운드
    state[:round] += 1
    state[:guarded] = {}
    state[:counter] = {}
    state[:current_turn] = state[:turn_order][(state[:turn_order].index(state[:current_turn]) + 1) % state[:turn_order].length]
    BattleState.update(battle_id, state)
    
    next_player = @sheet_manager.find_user(state[:current_turn])
    next_player_name = next_player ? (next_player["이름"] || state[:current_turn]) : state[:current_turn]
    
    message += "다음 라운드 시작\n"
    message += "#{next_player_name}의 차례\n"
    message += "[공격] [방어] [반격] [물약사용/크기]"
    
    reply_to_battle_thread(message, battle_id, state)
  end

  # 1:1 방어 수행
  def perform_1v1_defend(user_id, battle_id, state)
    user = @sheet_manager.find_user(user_id)
    user_name = user ? (user["이름"] || user_id) : user_id
    
    state[:guarded] ||= {}
    state[:guarded][user_id] = true
    
    message = "#{user_name}이(가) 방어 태세\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    
    state[:current_turn] = state[:turn_order][(state[:turn_order].index(state[:current_turn]) + 1) % state[:turn_order].length]
    BattleState.update(battle_id, state)
    
    next_player = @sheet_manager.find_user(state[:current_turn])
    next_player_name = next_player ? (next_player["이름"] || state[:current_turn]) : state[:current_turn]
    
    message += "#{next_player_name}의 차례\n"
    message += "[공격] [방어] [반격] [물약사용/크기]"
    
    reply_to_battle_thread(message, battle_id, state)
  end

  # 1:1 반격 수행
  def perform_1v1_counter(user_id, battle_id, state)
    user = @sheet_manager.find_user(user_id)
    user_name = user ? (user["이름"] || user_id) : user_id
    
    state[:counter] ||= {}
    state[:counter][user_id] = true
    
    message = "#{user_name}이(가) 반격 태세\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    
    state[:current_turn] = state[:turn_order][(state[:turn_order].index(state[:current_turn]) + 1) % state[:turn_order].length]
    BattleState.update(battle_id, state)
    
    next_player = @sheet_manager.find_user(state[:current_turn])
    next_player_name = next_player ? (next_player["이름"] || state[:current_turn]) : state[:current_turn]
    
    message += "#{next_player_name}의 차례\n"
    message += "[공격] [방어] [반격] [물약사용/크기]"
    
    reply_to_battle_thread(message, battle_id, state)
  end

  # 팀 액션 처리
  def handle_team_action(user_id, action_type, target_id, battle_id, state)
    # 타겟 검증 (공격 시)
    if action_type == :attack
      unless target_id
        reply_to_battle_thread("팀전투에서는 타겟을 지정해야 합니다.", battle_id, state)
        return
      end
      
      unless state[:participants].include?(target_id)
        reply_to_battle_thread("잘못된 타겟입니다.", battle_id, state)
        return
      end
      
      my_team = state[:teams][:team1].include?(user_id) ? :team1 : :team2
      if state[:teams][my_team].include?(target_id)
        reply_to_battle_thread("아군을 공격할 수 없습니다!", battle_id, state)
        return
      end
    end

    # 액션 큐에 추가
    state[:actions_queue] ||= []
    state[:actions_queue] << {
      user_id: user_id,
      action: action_type,
      target: target_id
    }

    user = @sheet_manager.find_user(user_id)
    user_name = user["이름"] || user_id
    
    action_text = case action_type
                  when :attack
                    target_name = (@sheet_manager.find_user(target_id) || {})["이름"] || target_id
                    "#{user_name}이(가) #{target_name}을(를) 공격 준비"
                  when :defend
                    "#{user_name}이(가) 방어 태세"
                  when :defend_target
                    target_name = (@sheet_manager.find_user(target_id) || {})["이름"] || target_id
                    "#{user_name}이(가) #{target_name}을(를) 방어 준비"
                  when :counter
                    "#{user_name}이(가) 반격 태세"
                  end
    
    message = "#{action_text}\n"
    message += "━━━━━━━━━━━━━━━━━━\n"

    state[:turn_index] += 1
    BattleState.update(battle_id, state)
    
    # 모든 참가자가 행동 선택 완료
    if state[:turn_index] >= state[:participants].length
      process_team_round(battle_id, state, message)
    else
      # 대기 중인 참가자 목록
      waiting = state[:participants].select.with_index do |pid, idx|
        idx >= state[:turn_index]
      end
      
      waiting_names = waiting.map { |pid| (@sheet_manager.find_user(pid)["이름"] || pid) }
      
      message += "대기 중: #{waiting_names.join(', ')}\n"
      message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"
      
      reply_to_battle_thread(message, battle_id, state)
    end
  end

  # 팀전투 라운드 처리
  def process_team_round(battle_id, state, prefix_message)
    # 1번 타래: 라운드 결과
    message1 = ""
    state[:participants].each { |pid| message1 += "@#{pid} " }
    message1 += "\n라운드 #{state[:round]} 결과\n"
    message1 += "━━━━━━━━━━━━━━━━━━\n\n"

    # 방어/반격 상태 설정
    state[:actions_queue].each do |action|
      if action[:action] == :defend
        state[:guarded] ||= {}
        state[:guarded][action[:user_id]] = true
      elsif action[:action] == :defend_target
        state[:guarded] ||= {}
        state[:guarded][action[:target]] = true
      elsif action[:action] == :counter
        state[:counter] ||= {}
        state[:counter][action[:user_id]] = true
      end
    end

    # 공격 처리
    state[:actions_queue].each do |action|
      next unless action[:action] == :attack
      
      attacker = @sheet_manager.find_user(action[:user_id])
      defender = @sheet_manager.find_user(action[:target])
      
      next unless attacker && defender
      
      result = calculate_attack_result(attacker, action[:user_id], defender, action[:target], state)
      message1 += result[:message] + "\n"
      
      # HP 업데이트
      if result[:damage] > 0
        new_hp = [(defender["HP"] || 100).to_i - result[:damage], 0].max
        @sheet_manager.update_user(action[:target], { hp: new_hp })
      end
      
      if result[:counter_damage] > 0
        attacker_new_hp = [(attacker["HP"] || 100).to_i - result[:counter_damage], 0].max
        @sheet_manager.update_user(action[:user_id], { hp: attacker_new_hp })
      end
    end

    # 1번 타래 전송
    result1 = @mastodon_client.reply(state[:reply_status], message1)
    
    # 0.5초 대기
    sleep 0.5

    # 2번 타래: 체력 현황
    message2 = "━━━━━━━━━━━━━━━━━━\n"
    message2 += "체력 현황\n"
    message2 += "━━━━━━━━━━━━━━━━━━\n"
    
    # 팀별 표시
    team1_names = state[:teams][:team1].map { |pid| (@sheet_manager.find_user(pid)["이름"] || pid) }
    team2_names = state[:teams][:team2].map { |pid| (@sheet_manager.find_user(pid)["이름"] || pid) }
    
    message2 += "팀1:\n"
    state[:teams][:team1].each do |pid|
      user = @sheet_manager.find_user(pid)
      next unless user
      
      user_name = user["이름"] || pid
      current_hp = (user["HP"] || 0).to_i
      max_hp = calculate_max_hp(user)
      hp_bar = create_hp_bar(current_hp, max_hp)
      status = current_hp > 0 ? "(생존)" : "(전투불능)"
      
      message2 += "- #{user_name}: #{hp_bar} #{current_hp}/#{max_hp} #{status}\n"
    end
    
    message2 += "\n팀2:\n"
    state[:teams][:team2].each do |pid|
      user = @sheet_manager.find_user(pid)
      next unless user
      
      user_name = user["이름"] || pid
      current_hp = (user["HP"] || 0).to_i
      max_hp = calculate_max_hp(user)
      hp_bar = create_hp_bar(current_hp, max_hp)
      status = current_hp > 0 ? "(생존)" : "(전투불능)"
      
      message2 += "- #{user_name}: #{hp_bar} #{current_hp}/#{max_hp} #{status}\n"
    end
    message2 += "━━━━━━━━━━━━━━━━━━\n\n"

    # 승부 판정
    team1_alive = state[:teams][:team1].count do |pid|
      u = @sheet_manager.find_user(pid)
      u && (u["HP"] || 0).to_i > 0
    end
    
    team2_alive = state[:teams][:team2].count do |pid|
      u = @sheet_manager.find_user(pid)
      u && (u["HP"] || 0).to_i > 0
    end

    if team1_alive == 0
      message2 += "팀2 승리!"
      @mastodon_client.reply(result1 || state[:reply_status], message2)
      BattleState.clear(battle_id)
      return
    elsif team2_alive == 0
      message2 += "팀1 승리!"
      @mastodon_client.reply(result1 || state[:reply_status], message2)
      BattleState.clear(battle_id)
      return
    end

    # 다음 라운드
    state[:round] += 1
    state[:turn_index] = 0
    state[:actions_queue] = []
    state[:guarded] = {}
    state[:counter] = {}
    BattleState.update(battle_id, state)

    message2 += "라운드 #{state[:round]} 시작\n"
    message2 += "모든 참가자는 행동을 선택하세요!\n"
    message2 += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"

    @mastodon_client.reply(result1 || state[:reply_status], message2)
  end

  # 공격 결과 계산
  def calculate_attack_result(attacker, attacker_id, defender, defender_id, state)
    attacker_name = attacker["이름"] || attacker_id
    defender_name = defender["이름"] || defender_id
    
    # 공격력 계산
    atk = (attacker["공격"] || 10).to_i
    atk_roll = rand(1..20)
    luck = (attacker["행운"] || 10).to_i
    
    crit_result = check_critical_hit(luck)
    atk_total = atk + atk_roll
    
    # 방어력 계산
    def_stat = (defender["방어"] || 10).to_i
    def_roll = rand(1..20)
    def_total = def_stat + def_roll
    
    # 기본 데미지
    damage = [atk_total - def_total, 0].max
    
    # 치명타
    if crit_result[:is_crit]
      damage = (damage * 1.5).to_i
    end

    # 방어 상태 확인
    guard_text = ""
    counter_damage = 0
    
    if state.dig(:guarded, defender_id)
      guard_roll = rand(1..20)
      guard_total = def_stat + guard_roll
      
      if guard_total >= atk_total
        damage = 0
        guard_text = " / 방어 성공!"
      else
        guard_text = " / 방어 실패"
      end
    end
    
    # 반격 상태 확인
    if state.dig(:counter, defender_id) && damage > 0
      counter_damage = 5
      guard_text += "\n#{defender_name}의 반격 발동!\n"
      guard_text += "#{attacker_name} 반격 피해: 5"
    end

    message = "#{attacker_name}의 공격 vs #{defender_name}\n"
    message += "공격: #{atk} + #{atk_roll} = #{atk_total}"
    message += " [치명타!]" if crit_result[:is_crit]
    message += "\n"
    message += "방어: #{def_stat} + #{def_roll} = #{def_total}#{guard_text}\n"
    message += "데미지: #{damage}"

    {
      message: message,
      damage: damage,
      counter_damage: counter_damage
    }
  end
end
