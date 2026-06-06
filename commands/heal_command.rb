# commands/heal_command.rb
# 전투 외 물약 사용 명령어

class HealCommand
  # 물약 종류별 회복량 (고정값)
  POTION_TYPES = {
    "소형 물약" => 10,
    "중형 물약" => 30,
    "대형 물약" => 50,
    "물약" => 20        # 기본 물약
  }

  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  def use_potion(user_id, reply_status, potion_type = nil)
    user = @sheet_manager.find_user(user_id)
    
    unless user
      @mastodon_client.reply(reply_status, "@#{user_id} 등록되지 않은 사용자입니다.")
      return
    end

    # 아이템 확인
    items = user["아이템"] || user[:items] || ""
    
    # 물약이 하나도 없으면 (어떤 종류든)
    unless items.include?("물약")
      @mastodon_client.reply(reply_status, "@#{user_id} 물약이 없습니다. 상점에서 구매하세요.")
      return
    end

    # 현재 체력
    current_hp = (user["HP"] || user[:hp] || 100).to_i
    
    # 이미 최대 체력이면
    if current_hp >= 100
      @mastodon_client.reply(reply_status, "@#{user_id} 이미 최대 체력입니다. (100/100)")
      return
    end

    # 보유한 물약 목록 추출
    available_potions = []
    POTION_TYPES.keys.each do |potion|
      available_potions << potion if items.include?(potion)
    end

    if available_potions.empty?
      @mastodon_client.reply(reply_status, "@#{user_id} 사용 가능한 물약이 없습니다.")
      return
    end

    # 물약 타입이 지정되지 않았으면 선택지 제공
    if potion_type.nil?
      name = user["이름"] || user[:name] || user_id
      msg = "@#{user_id}\n"
      msg += "━━━━━━━━━━━━━━━━━━\n"
      msg += "#{name}의 물약 목록\n"
      msg += "━━━━━━━━━━━━━━━━━━\n"
      available_potions.each do |potion|
        heal = POTION_TYPES[potion]
        msg += "• #{potion} (회복: #{heal})\n"
      end
      msg += "━━━━━━━━━━━━━━━━━━\n"
      msg += "사용법:\n"
      msg += "[회복/소형] - 소형 물약 사용\n"
      msg += "[회복/중형] - 중형 물약 사용\n"
      msg += "[회복/대형] - 대형 물약 사용"
      
      @mastodon_client.reply(reply_status, msg)
      return
    end

    # 지정된 물약 타입 찾기
    potion_found = nil
    case potion_type
    when /소형/i
      potion_found = "소형 물약" if items.include?("소형 물약")
    when /중형/i
      potion_found = "중형 물약" if items.include?("중형 물약")
    when /대형/i
      potion_found = "대형 물약" if items.include?("대형 물약")
    when /기본|일반/i
      potion_found = "물약" if items.include?("물약")
    end

    unless potion_found
      @mastodon_client.reply(reply_status, "@#{user_id} 해당 종류의 물약이 없습니다.")
      return
    end

    heal_amount = POTION_TYPES[potion_found]

    # 회복
    new_hp = [current_hp + heal_amount, 100].min
    actual_heal = new_hp - current_hp

    # HP 업데이트
    @sheet_manager.update_user(user_id, { hp: new_hp })

    # 물약 제거 (정확히 일치하는 것만 제거)
    new_items = items.sub(potion_found, "").gsub(/,+/, ",").gsub(/^,|,$/, "").strip
    @sheet_manager.update_user(user_id, { items: new_items })

    name = user["이름"] || user[:name] || user_id
    
    msg = "@#{user_id}\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "#{name}이(가) #{potion_found}을 사용했습니다.\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "회복량: #{actual_heal}\n"
    msg += "체력: #{current_hp} → #{new_hp}\n"
    msg += "━━━━━━━━━━━━━━━━━━"

    @mastodon_client.reply(reply_status, msg)
  end
end
