require_relative '../core/battle_state'

class PotionCommand
  POTION_EFFECTS = {
    "소형" => 10,
    "중형" => 30,
    "대형" => 50
  }

  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  # 평상시 또는 전투 중 본인에게 물약 사용
  def use_potion(user_id, reply_status, potion_type)
    user = @sheet_manager.find_user(user_id)
    unless user
      @mastodon_client.reply(reply_status, "등록되지 않은 사용자입니다.")
      return
    end

    potion_name = "#{potion_type}물약"
    heal_amount = POTION_EFFECTS[potion_type]
    
    unless heal_amount
      @mastodon_client.reply(reply_status, "알 수 없는 물약 종류입니다.")
      return
    end

    # 아이템 배열 처리 (Array 또는 String)
    items = user["아이템"]
    items = items.is_a?(Array) ? items : items.to_s.split(',').map(&:strip)
    
    unless items.include?(potion_name)
      @mastodon_client.reply(reply_status, "#{potion_name}을(를) 보유하고 있지 않습니다.")
      return
    end

    # 물약 제거
    items.delete_at(items.index(potion_name))
    
    # 체력 회복
    current_hp = (user["HP"] || 100).to_i
    vitality_stat = (user["체력"] || 0).to_i
    max_hp = 100 + (vitality_stat * 10)
    new_hp = [current_hp + heal_amount, max_hp].min
    
    @sheet_manager.update_user(user_id, { 
      hp: new_hp,
      items: items
    })

    user_name = user["이름"] || user_id
    hp_bar = create_hp_bar(new_hp, max_hp)
    
    message = "#{user_name}이(가) #{potion_name} 사용!\n"
    message += "HP +#{heal_amount} (#{current_hp} → #{new_hp})\n"
    message += "#{hp_bar} #{new_hp}/#{max_hp}"
    
    # 전투 중이라면 턴 소모
    battle_id = BattleState.find_battle_id_by_user(user_id)
    if battle_id
      state = BattleState.get(battle_id)
      if state && state[:current_turn].to_s == user_id.to_s
        message += "\n━━━━━━━━━━━━━━━━━━\n"
        
        # 턴 넘기기
        if state[:type] == "1v1"
          opponent_id = state[:participants].find { |p| p != user_id }
          state[:current_turn] = opponent_id
          state[:last_action_time] = Time.now
          BattleState.update(battle_id, state)
          
          opponent = @sheet_manager.find_user(opponent_id)
          opponent_name = opponent ? (opponent["이름"] || opponent_id) : opponent_id
          
          message += "#{opponent_name}의 차례\n"
          message += "[공격] [방어] [반격] [물약사용/크기]"
        elsif state[:type] == "2v2" || state[:type] == "4v4"
          # 팀전투에서는 액션 큐에 추가
          state[:actions_queue] ||= []
          state[:actions_queue] << {
            user_id: user_id,
            action: :use_potion,
            potion_type: potion_type
          }
          
          state[:turn_index] += 1
          state[:last_action_time] = Time.now
          BattleState.update(battle_id, state)
          
          total_participants = state[:participants].length
          if state[:turn_index] >= total_participants
            # 라운드 처리는 battle_engine에서
            message += "대기 중..."
          else
            state[:current_turn] = state[:turn_order][state[:turn_index]]
            BattleState.update(battle_id, state)
            
            next_player = @sheet_manager.find_user(state[:current_turn])
            next_player_name = next_player["이름"] || state[:current_turn]
            
            message += "#{next_player_name}의 차례\n"
            message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"
          end
        end
      end
    end
    
    @mastodon_client.reply(reply_status, message)
  end

  # 팀전투에서 아군에게 물약 사용
  def use_potion_for_target(user_id, reply_status, potion_type, target_id)
    battle_id = BattleState.find_battle_id_by_user(user_id)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.reply(reply_status, "현재 전투 중이 아닙니다.")
      return
    end

    unless state[:current_turn].to_s == user_id.to_s
      @mastodon_client.reply(reply_status, "당신의 차례가 아닙니다.")
      return
    end

    unless state[:participants].include?(target_id)
      @mastodon_client.reply(reply_status, "전투 참가자가 아닙니다.")
      return
    end

    user = @sheet_manager.find_user(user_id)
    target = @sheet_manager.find_user(target_id)
    
    unless user && target
      @mastodon_client.reply(reply_status, "등록되지 않은 사용자입니다.")
      return
    end

    potion_name = "#{potion_type}물약"
    heal_amount = POTION_EFFECTS[potion_type]
    
    unless heal_amount
      @mastodon_client.reply(reply_status, "알 수 없는 물약 종류입니다.")
      return
    end

    # 아이템 배열 처리
    items = user["아이템"]
    items = items.is_a?(Array) ? items : items.to_s.split(',').map(&:strip)
    
    unless items.include?(potion_name)
      @mastodon_client.reply(reply_status, "#{potion_name}을(를) 보유하고 있지 않습니다.")
      return
    end

    # 물약 제거
    items.delete_at(items.index(potion_name))
    @sheet_manager.update_user(user_id, { items: items })

    # 타겟 체력 회복
    current_hp = (target["HP"] || 100).to_i
    vitality_stat = (target["체력"] || 0).to_i
    max_hp = 100 + (vitality_stat * 10)
    new_hp = [current_hp + heal_amount, max_hp].min
    
    @sheet_manager.update_user(target_id, { hp: new_hp })

    user_name = user["이름"] || user_id
    target_name = target["이름"] || target_id
    hp_bar = create_hp_bar(new_hp, max_hp)
    
    message = "#{user_name}이(가) #{target_name}에게 #{potion_name} 사용!\n"
    message += "HP +#{heal_amount} (#{current_hp} → #{new_hp})\n"
    message += "#{hp_bar} #{new_hp}/#{max_hp}\n"
    message += "━━━━━━━━━━━━━━━━━━\n"

    # 턴 넘기기
    state[:actions_queue] ||= []
    state[:actions_queue] << {
      user_id: user_id,
      action: :heal_target,
      target: target_id,
      potion_type: potion_type
    }
    
    state[:turn_index] += 1
    state[:last_action_time] = Time.now
    BattleState.update(battle_id, state)
    
    total_participants = state[:participants].length
    if state[:turn_index] >= total_participants
      message += "대기 중..."
    else
      state[:current_turn] = state[:turn_order][state[:turn_index]]
      BattleState.update(battle_id, state)
      
      next_player = @sheet_manager.find_user(state[:current_turn])
      next_player_name = next_player["이름"] || state[:current_turn]
      
      message += "#{next_player_name}의 차례\n"
      message += "[공격/@타겟] [방어/@타겟] [반격] [물약사용/크기/@타겟]"
    end
    
    @mastodon_client.reply(reply_status, message)
  end

  private

  def create_hp_bar(current_hp, max_hp)
    percentage = [current_hp.to_f / max_hp, 1.0].min
    filled_length = (percentage * 10).round
    
    filled = "█" * filled_length
    empty = "░" * (10 - filled_length)
    
    filled + empty
  end
end
