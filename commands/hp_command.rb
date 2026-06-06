class HpCommand
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  def check_hp(user_id, reply_status)
    user = @sheet_manager.find_user(user_id)
    
    unless user
      @mastodon_client.reply(reply_status, "등록되지 않은 사용자입니다.")
      return
    end

    user_name = user["이름"] || user_id
    current_hp = (user["HP"] || 100).to_i
    vitality_stat = (user["체력"] || 0).to_i
    max_hp = 100 + (vitality_stat * 10)
    
    hp_bar = create_hp_bar(current_hp, max_hp)
    
    message = "#{user_name}의 체력:\n"
    message += "#{hp_bar} #{current_hp}/#{max_hp}"
    
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
