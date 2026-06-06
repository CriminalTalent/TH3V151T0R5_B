class BattleState
  @battles = {}
  @mutex = Mutex.new

  def self.create(participants, data = {})
    battle_id = generate_battle_id(participants)
    
    @mutex.synchronize do
      @battles[battle_id] = data.merge(
        participants: participants,
        created_at: Time.now,
        start_time: Time.now,
        last_action_time: Time.now
      )
    end
    
    battle_id
  end

  def self.get(battle_id)
    @mutex.synchronize { @battles[battle_id] }
  end

  def self.update(battle_id, data)
    @mutex.synchronize do
      if @battles[battle_id]
        @battles[battle_id].merge!(data)
      end
    end
  end

  def self.clear(battle_id)
    @mutex.synchronize { @battles.delete(battle_id) }
  end

  def self.find_battle_id_by_user(user_id)
    @mutex.synchronize do
      @battles.find { |id, state| state[:participants].include?(user_id) }&.first
    end
  end

  def self.find_by_user(user_id)
    battle_id = find_battle_id_by_user(user_id)
    battle_id ? get(battle_id) : nil
  end

  def self.find_battle_by_participants(participants)
    @mutex.synchronize do
      @battles.find do |id, state|
        state[:participants].sort == participants.sort
      end&.first
    end
  end

  def self.all_battles
    @mutex.synchronize { @battles.dup }
  end

  def self.cleanup_stalled_battles
    now = Time.now
    stalled = []
    
    @mutex.synchronize do
      @battles.each do |battle_id, state|
        # 2시간 이상 된 전투는 자동 삭제
        if now - state[:created_at] > 7200
          stalled << battle_id
        end
      end
      
      stalled.each { |id| @battles.delete(id) }
    end
    
    stalled.length
  end

  def self.check_timeouts
    now = Time.now
    timeout_battles = []
    
    @mutex.synchronize do
      @battles.each do |battle_id, state|
        # 전체 전투 1시간 초과
        if now - state[:start_time] > 3600
          timeout_battles << { id: battle_id, type: :battle_timeout }
        # 턴 4분 초과
        elsif state[:last_action_time] && now - state[:last_action_time] > 240
          timeout_battles << { id: battle_id, type: :turn_timeout }
        end
      end
    end
    
    timeout_battles
  end

  private

  def self.generate_battle_id(participants)
    timestamp = Time.now.to_i
    random = rand(1000..9999)
    "battle_#{participants.join('_')}_#{timestamp}_#{random}"
  end
end
