require_relative '../core/battle_state'
require_relative '../core/battle_engine'

class BattleCommand
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager   = sheet_manager
    @engine          = BattleEngine.new(mastodon_client, sheet_manager)
  end

  def start_1v1(user1_id, user2_id, reply_status)
    @engine.start_1v1(user1_id, user2_id, reply_status)
  end

  def start_2v2(user1_id, user2_id, user3_id, user4_id, reply_status)
    @engine.start_2v2(user1_id, user2_id, user3_id, user4_id, reply_status)
  end

  def start_4v4(u1, u2, u3, u4, u5, u6, u7, u8, reply_status)
    @engine.start_4v4(u1, u2, u3, u4, u5, u6, u7, u8, reply_status)
  end

  def attack(user_id, target_id, reply_status)
    @engine.attack(user_id, target_id)
  end

  def defend(user_id, target_id, reply_status)
    if target_id
      @engine.defend_target(user_id, target_id)
    else
      @engine.defend(user_id)
    end
  end

  def counter(user_id, reply_status)
    @engine.counter(user_id)
  end
end
