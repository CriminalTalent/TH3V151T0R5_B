require_relative 'core/battle_state'

class BattleTimer
  TEAM_NAMES = {
    team1: "불사조 기사단",
    team2: "이그드라실"
  }

  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
    @running = false
  end

  def start
    @running = true
    
    Thread.new do
      while @running
        sleep 30 # 30초마다 체크
        check_all_battles
      end
    end
    
    puts "[타이머] 전투 시간 제한 감시 시작"
  end

  def stop
    @running = false
  end

  private

  def check_all_battles
    timeouts = BattleState.check_timeouts
    
    timeouts.each do |timeout_info|
      battle_id = timeout_info[:id]
      state = BattleState.get(battle_id)
      next unless state
      
      if timeout_info[:type] == :battle_timeout
        handle_battle_timeout(battle_id, state)
      elsif timeout_info[:type] == :turn_timeout
        handle_turn_timeout(battle_id, state)
      end
    end
    
    # 오래된 전투 정리
    cleaned = BattleState.cleanup_stalled_battles
    puts "[타이머] 오래된 전투 #{cleaned}개 정리" if cleaned > 0
  end

  def handle_turn_timeout(battle_id, state)
    current_user = state[:current_turn]
    user = @sheet_manager.find_user(current_user)
    user_name = user ? (user["이름"] || current_user) : current_user
    
    puts "[타이머] #{battle_id}: #{user_name} 턴 시간 초과 (4분) - 자동 방어"
    
    message = "시간 초과!\n"
    message += "#{user_name}이(가) 4분 내에 행동하지 않아 자동으로 방어합니다.\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    
    # 방어 태세 설정
    state[:guarded] ||= {}
    state[:guarded][current_user] = true
    
    # 턴 넘기기
    if state[:type] == "1v1"
      opponent_id = state[:participants].find { |p| p != current_user }
      state[:current_turn] = opponent_id
      state[:last_action_time] = Time.now
      BattleState.update(battle_id, state)
      
      opponent = @sheet_manager.find_user(opponent_id)
      opponent_name = opponent ? (opponent["이름"] || opponent_id) : opponent_id
      
      message += "#{opponent_name}의 차례\n"
      message += "[공격] [방어] [반격] [물약사용/크기]"
      
    elsif state[:type] == "2v2" || state[:type] == "4v4"
      state[:actions_queue] ||= []
      state[:actions_queue] << {
        user_id: current_user,
        action: :defend
      }
      
      state[:turn_index] += 1
      state[:last_action_time] = Time.now
      
      total_participants = state[:participants].length
      if state[:turn_index] >= total_participants
        message += "모든 참가자 행동 완료. 라운드 처리 중..."
        # 라운드 처리는 battle_engine에서
      else
        state[:current_turn] = state[:turn_order][state[:turn_index]]
        BattleState.update(battle_id, state)
        
        next_player = @sheet_manager.find_user(state[:current_turn])
        next_player_name = next_player["이름"] || state[:current_turn]
        
        message += "#{next_player_name}의 차례\n"
        message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"
      end
      
      BattleState.update(battle_id, state)
    end
    
    if state[:reply_status]
      @mastodon_client.reply(state[:reply_status], message)
    end
  end

  def handle_battle_timeout(battle_id, state)
    puts "[타이머] #{battle_id}: 전투 시간 초과 (1시간) - HP 합산으로 승부 결정"
    
    message = "전투 시간 1시간 초과!\n"
    message += "━━━━━━━━━━━━━━━━━━\n"
    
    if state[:type] == "1v1"
      # 1:1은 HP가 높은 쪽 승리
      p1_id = state[:participants][0]
      p2_id = state[:participants][1]
      
      p1 = @sheet_manager.find_user(p1_id)
      p2 = @sheet_manager.find_user(p2_id)
      
      p1_hp = (p1["HP"] || 0).to_i
      p2_hp = (p2["HP"] || 0).to_i
      
      p1_name = p1["이름"] || p1_id
      p2_name = p2["이름"] || p2_id
      
      message += "#{p1_name}: #{p1_hp}HP\n"
      message += "#{p2_name}: #{p2_hp}HP\n"
      message += "━━━━━━━━━━━━━━━━━━\n"
      
      if p1_hp > p2_hp
        message += "#{p1_name} 승리! (체력 총합)"
      elsif p2_hp > p1_hp
        message += "#{p2_name} 승리! (체력 총합)"
      else
        message += "무승부!"
      end
      
    elsif state[:type] == "2v2" || state[:type] == "4v4"
      # 팀전은 팀별 HP 합산
      team1_hp = state[:teams][:team1].sum do |pid|
        u = @sheet_manager.find_user(pid)
        u ? (u["HP"] || 0).to_i : 0
      end
      
      team2_hp = state[:teams][:team2].sum do |pid|
        u = @sheet_manager.find_user(pid)
        u ? (u["HP"] || 0).to_i : 0
      end
      
      team1_name = TEAM_NAMES[:team1]
      team2_name = TEAM_NAMES[:team2]
      
      message += "팀별 체력 총합:\n"
      message += "#{team1_name}: #{team1_hp}HP\n"
      message += "#{team2_name}: #{team2_hp}HP\n"
      message += "━━━━━━━━━━━━━━━━━━\n"
      
      if team1_hp > team2_hp
        message += "#{team1_name} 승리! (체력 총합)"
      elsif team2_hp > team1_hp
        message += "#{team2_name} 승리! (체력 총합)"
      else
        message += "무승부!"
      end
    end
    
    if state[:reply_status]
      @mastodon_client.reply(state[:reply_status], message)
    end
    
    BattleState.clear(battle_id)
  end
end
