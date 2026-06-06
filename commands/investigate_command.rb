# commands/investigate_command.rb
require 'date'
require 'time'

class InvestigateCommand
  DAILY_MOVE_LIMIT = 3

  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  def execute(text, user_id, reply_status)
    case text
    when /\[조사시작\]/i
      start_investigation(user_id, reply_status)
    when /\[조사\/(.+)\]/i
      handle_location($1.strip, user_id, reply_status)
    when /\[세부조사\/(.+)\]/i
      handle_detail($1.strip, user_id, reply_status)
    when /\[이동\/(.+)\]/i
      move_to_location($1.strip, user_id, reply_status)
    when /\[위치확인\]/i
      check_location(user_id, reply_status)
    when /\[협력조사\/(.+)\/@(.+)\]/i
      cooperate_investigation($1.strip, $2.strip, user_id, reply_status)
    when /\[방해\/@(.+)\]/i
      disturb_investigation($1.strip, user_id, reply_status)
    when /\[조사종료\]/i
      end_investigation(user_id, reply_status)
    else
      @mastodon_client.reply_direct(
        reply_status,
        "@#{user_id}\n가능한 명령:\n" \
        "[조사시작], [조사/위치], [세부조사/대상], [이동/위치], [위치확인], [협력조사/대상/@상대], [방해/@상대], [조사종료]"
      )
    end
  rescue => e
    puts "[에러] 조사 처리 중 오류: #{e.message}"
    puts e.backtrace.first(5)
    @mastodon_client.reply_direct(reply_status, "@#{user_id} 조사 처리 중 오류가 발생했습니다. 잠시 후 다시 시도해주세요.")
  end

  private

  def normalize_location(s)
    s.to_s.strip.gsub(/\p{Cf}/, '')
  end

  # 보상 파싱 및 지급
  def process_rewards(user_id, result_text)
    return unless result_text

    # [아이템:아이템명] 추출
    items = result_text.scan(/\[아이템:([^\]]+)\]/).flatten
    # [갈레온:숫자] 추출
    galleons_match = result_text.match(/\[갈레온:(\d+)\]/)
    galleons = galleons_match ? galleons_match[1].to_i : 0

    return if items.empty? && galleons == 0

    user = @sheet_manager.find_user(user_id)
    return unless user

    rewards = []

    # 아이템 지급
    if items.any?
      current_items = user["아이템"].to_s.split(",").map(&:strip).reject(&:empty?)
      new_items = current_items + items
      @sheet_manager.update_user(user_id, { items: new_items.join(", ") })
      rewards << "아이템: #{items.join(', ')}"
    end

    # 갈레온 지급
    if galleons > 0
      current_galleons = user["갈레온"].to_i
      new_galleons = current_galleons + galleons
      @sheet_manager.update_user(user_id, { galleons: new_galleons })
      rewards << "갈레온: +#{galleons}G (총 #{new_galleons}G)"
    end

    rewards
  end

  # 보상 메시지 제거 (사용자에게 보이는 텍스트 정리)
  def clean_result_text(text)
    text.to_s.gsub(/\[아이템:[^\]]+\]/, '').gsub(/\[갈레온:\d+\]/, '').strip
  end

  # === [조사시작]
  def start_investigation(user_id, reply_status)
    user = @sheet_manager.find_user(user_id)
    unless user
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 등록되지 않은 사용자입니다. [입학/이름]으로 먼저 등록해주세요.")
      return
    end

    # Direct 답글로 전송 (비공개)
    locations = @sheet_manager.available_locations
    msg = "@#{user_id}\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "조사 시작\n"
    msg += "━━━━━━━━━━━━━━━━━━\n\n"
    msg += "탐색 가능한 장소:\n"
    msg += locations.map { |loc| "- #{loc}" }.join("\n")
    msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
    msg += "[조사/위치] [위치확인] [조사종료]"
    
    @mastodon_client.reply_direct(reply_status, msg)
  end

  # === [조사/위치]
  def handle_location(location, user_id, reply_status)
    unless @sheet_manager.is_location?(location)
      @mastodon_client.reply_direct(reply_status, "@#{user_id} #{location}은(는) 조사 가능한 위치가 아닙니다.")
      return
    end

    @sheet_manager.update_investigation_state(user_id, "진행중", location)

    # 위치 정보 조회
    row = @sheet_manager.find_investigation_entry(location, "조사")
    
    msg = "@#{user_id}\n"
    
    if row
      # 난이도 판정
      user = @sheet_manager.find_user(user_id)
      luck = (user["행운"] || 0).to_i
      dice = rand(1..20)
      difficulty = row["난이도"].to_i
      total = dice + luck
      success = total >= difficulty
      
      # 결과 메시지
      msg += "━━━━━━━━━━━━━━━━━━\n"
      msg += "위치: #{location}\n"
      msg += "━━━━━━━━━━━━━━━━━━\n\n"
      msg += "판정: #{dice} + 행운 #{luck} = #{total}\n"
      msg += "난이도: #{difficulty}\n"
      msg += "결과: #{success ? '성공' : '실패'}\n\n"
      msg += "━━━━━━━━━━━━━━━━━━\n"
      
      result_text = success ? row["성공결과"] : row["실패결과"]
      
      # 보상 처리
      rewards = process_rewards(user_id, result_text)
      
      # 보상 태그 제거한 텍스트
      clean_text = clean_result_text(result_text)
      msg += clean_text
      
      # 보상 정보 추가
      if rewards && rewards.any?
        msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
        msg += "획득:\n"
        msg += rewards.map { |r| "• #{r}" }.join("\n")
      end
      
      # 로그 기록
      @sheet_manager.log_investigation(user_id, location, location, "조사", success, result_text)
    else
      # 개요 정보만 있는 경우
      overview = @sheet_manager.location_overview_outputs(location)
      
      if overview.any?
        msg += "━━━━━━━━━━━━━━━━━━\n"
        msg += "#{location}\n"
        msg += "━━━━━━━━━━━━━━━━━━\n\n"
        msg += overview.join("\n\n")
      end
    end

    # 같은 위치에 있는 다른 사용자들 표시
    other_users = @sheet_manager.users_at_location(location).reject { |u| u == user_id }
    if other_users.any?
      msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
      msg += "이 위치에 있는 사람들:\n"
      msg += other_users.map { |u| "@#{u}" }.join(", ")
    end

    # 세부 조사 대상 안내 (같은 메시지에 포함)
    details = @sheet_manager.detail_candidates(location)
    if details.any?
      msg += "\n\n세부 조사 가능:\n"
      msg += details.map { |d| "- #{d}" }.join("\n")
      msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
      if other_users.any?
        msg += "[세부조사/대상] [협력조사/대상/@상대] [방해/@상대] [이동/위치] [위치확인] [조사종료]"
      else
        msg += "[세부조사/대상] [이동/위치] [위치확인] [조사종료]"
      end
    else
      msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
      if other_users.any?
        msg += "[협력조사/대상/@상대] [방해/@상대] [이동/위치] [위치확인] [조사종료]"
      else
        msg += "[이동/위치] [위치확인] [조사종료]"
      end
    end
    
    # 한 번에 전송
    @mastodon_client.reply_direct(reply_status, msg)
  end

  # === [세부조사/대상]
  def handle_detail(target, user_id, reply_status)
    state = @sheet_manager.get_investigation_state(user_id)
    if state["조사상태"] != "진행중"
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 먼저 [조사/장소]로 위치를 지정해주세요.")
      return
    end

    location = state["위치"]
    row = @sheet_manager.find_investigation_entry(target, "정밀조사")
    unless row
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 지금은 #{target}을(를) 조사할 수 없습니다.")
      return
    end

    user = @sheet_manager.find_user(user_id)
    luck = (user["행운"] || 0).to_i

    dice = rand(1..20)
    difficulty = row["난이도"].to_i

    # 방해 디버프 확인
    status_effect = state["협력상태"].to_s.strip
    debuff = 0
    if status_effect == "방해"
      debuff = -3
      @sheet_manager.clear_status_effect(user_id)
    end

    total = dice + luck + debuff
    success = total >= difficulty
    result = success ? row["성공결과"] : row["실패결과"]

    # 보상 처리
    rewards = process_rewards(user_id, result)
    clean_text = clean_result_text(result)

    # Direct 답글로 상세 결과 전송
    msg = "@#{user_id}\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "정밀 조사: #{target}\n"
    msg += "위치: #{location}\n"
    msg += "━━━━━━━━━━━━━━━━━━\n\n"
    msg += "판정: #{dice} + 행운 #{luck}"
    msg += " #{debuff}" if debuff != 0
    msg += " = #{total}\n"
    msg += "난이도: #{difficulty}\n"
    msg += "결과: #{success ? '성공' : '실패'}\n\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += clean_text
    
    # 보상 정보 추가
    if rewards && rewards.any?
      msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
      msg += "획득:\n"
      msg += rewards.map { |r| "• #{r}" }.join("\n")
    end
    
    msg += "\n━━━━━━━━━━━━━━━━━━\n"
    msg += "[세부조사/대상] [이동/위치] [위치확인] [조사종료]"

    @mastodon_client.reply_direct(reply_status, msg)
    
    # 로그 기록
    @sheet_manager.log_investigation(user_id, location, target, "정밀조사", success, result)
  end

  # === [이동/위치]
  def move_to_location(location, user_id, reply_status)
    state = @sheet_manager.get_investigation_state(user_id)
    
    # 위치 유효성 먼저 확인 (포인트 차감 전)
    unless @sheet_manager.is_location?(location)
      @mastodon_client.reply_direct(reply_status, "@#{user_id} #{location}은(는) 이동할 수 있는 위치가 아닙니다.")
      return
    end

    # 포인트 확인
    points = state["이동포인트"].to_i
    if points <= 0
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 이동 포인트가 부족합니다. (하루 3회 한정, 자정에 초기화)")
      return
    end

    # 이동 성공 후 포인트 차감
    new_points = points - 1
    @sheet_manager.update_move_points(user_id, new_points)
    @sheet_manager.update_investigation_state(user_id, "진행중", location)

    msg = "@#{user_id}\n"
    msg += "#{location}(으)로 이동했습니다.\n"
    msg += "남은 이동 포인트: #{new_points}/3\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "[조사/위치] [세부조사/대상] [위치확인] [조사종료]"
    @mastodon_client.reply_direct(reply_status, msg)
  end

  # === [위치확인]
  def check_location(user_id, reply_status)
    state = @sheet_manager.get_investigation_state(user_id)
    location = state["위치"] || "-"
    points = state["이동포인트"] || 0
    status = state["조사상태"] || "없음"
    stealth = state["은밀도"] || 0
    cooperation = state["협력상태"] || "-"
    
    msg = "@#{user_id}\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "조사 상태\n"
    msg += "━━━━━━━━━━━━━━━━━━\n\n"
    msg += "현재 위치: #{location}\n"
    msg += "남은 이동 포인트: #{points}/3\n"
    msg += "조사 상태: #{status}\n"
    msg += "은밀도: #{stealth}/100\n"
    msg += "협력 상태: #{cooperation}\n"
    msg += "\n━━━━━━━━━━━━━━━━━━\n"
    
    if location != "-"
      msg += "[조사/위치] [세부조사/대상] [이동/위치] [협력조사/대상/@상대] [방해/@상대] [조사종료]"
    else
      msg += "[조사시작] [조사/위치]"
    end
    
    @mastodon_client.reply_direct(reply_status, msg)
  end

  # === [협력조사/대상/@상대]
  def cooperate_investigation(target, partner_name, user_id, reply_status)
    partner_id = partner_name

    state = @sheet_manager.get_investigation_state(user_id)
    partner_state = @sheet_manager.get_investigation_state(partner_id)

    if state["조사상태"] != "진행중"
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 당신은 아직 조사 중이 아닙니다.")
      return
    end

    if partner_state["조사상태"] != "진행중"
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 상대(@#{partner_name})는 현재 조사 중이 아닙니다.")
      return
    end

    loc1 = normalize_location(state["위치"])
    loc2 = normalize_location(partner_state["위치"])
    if loc1 != loc2
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 같은 위치에 있어야 협력 조사 가능합니다.")
      return
    end

    row = @sheet_manager.find_investigation_entry(target, "정밀조사")
    unless row
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 이곳에서 #{target}은(는) 협력 조사할 수 없습니다.")
      return
    end

    user = @sheet_manager.find_user(user_id)
    partner_user = @sheet_manager.find_user(partner_id)

    base_luck = (user["행운"] || 0).to_i + (partner_user["행운"] || 0).to_i
    temp_luck = base_luck + 5

    dice = rand(1..20)
    difficulty = row["난이도"].to_i
    total = dice + temp_luck
    success = total >= difficulty
    result = success ? row["성공결과"] : row["실패결과"]

    # 협력상태를 시트에 기록
    @sheet_manager.set_status_effect(user_id, "협력조사:#{partner_name}")
    @sheet_manager.set_status_effect(partner_id, "협력조사:#{user_id}")

    # 보상 처리 (양쪽 모두에게)
    rewards_user = process_rewards(user_id, result)
    rewards_partner = process_rewards(partner_id, result)
    clean_text = clean_result_text(result)

    # Direct 답글로 전송 (양쪽 모두 멘션)
    msg = "@#{user_id} @#{partner_name}\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "협력 조사\n"
    msg += "━━━━━━━━━━━━━━━━━━\n\n"
    msg += "참가자: @#{user_id} x @#{partner_name}\n"
    msg += "위치: #{loc1}\n"
    msg += "대상: #{target}\n\n"
    msg += "판정: #{dice}\n"
    msg += "행운: #{temp_luck} (기본 #{base_luck} + 협력 +5)\n"
    msg += "최종: #{total} vs 난이도 #{difficulty}\n"
    msg += "결과: #{success ? '성공' : '실패'}\n\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += clean_text
    
    # 보상 정보 추가
    if (rewards_user && rewards_user.any?) || (rewards_partner && rewards_partner.any?)
      msg += "\n\n━━━━━━━━━━━━━━━━━━\n"
      msg += "획득:\n"
      if rewards_user && rewards_user.any?
        msg += "@#{user_id}:\n"
        msg += rewards_user.map { |r| "  • #{r}" }.join("\n")
      end
      if rewards_partner && rewards_partner.any?
        msg += "\n" if rewards_user && rewards_user.any?
        msg += "@#{partner_name}:\n"
        msg += rewards_partner.map { |r| "  • #{r}" }.join("\n")
      end
    end
    
    msg += "\n━━━━━━━━━━━━━━━━━━\n"
    msg += "[세부조사/대상] [협력조사/대상/@상대] [방해/@상대] [조사종료]"

    @mastodon_client.reply_direct(reply_status, msg)

    # 로그 기록
    @sheet_manager.log_investigation(user_id, loc1, target, "협력조사", success, result)
    @sheet_manager.log_investigation(partner_id, loc1, target, "협력조사", success, result)
    
    # 협력 완료 후 상태 초기화
    @sheet_manager.clear_status_effect(user_id)
    @sheet_manager.clear_status_effect(partner_id)
  end

  # === [방해/@상대]
  def disturb_investigation(target_user, user_id, reply_status)
    target_id = target_user

    state = @sheet_manager.get_investigation_state(user_id)
    target_state = @sheet_manager.get_investigation_state(target_id)

    if state["조사상태"] != "진행중"
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 당신은 아직 조사 중이 아닙니다.")
      return
    end

    if target_state["조사상태"] != "진행중"
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 상대(@#{target_user})는 현재 조사 중이 아닙니다.")
      return
    end

    if normalize_location(state["위치"]) != normalize_location(target_state["위치"])
      @mastodon_client.reply_direct(reply_status, "@#{user_id} 같은 위치에 있어야 방해할 수 있습니다.")
      return
    end

    location = state["위치"]
    
    # 시트에 방해 상태 기록
    @sheet_manager.set_status_effect(target_id, "방해")

    # 로그에 기록
    @sheet_manager.log_investigation(user_id, location, target_user, "방해", true, "#{target_user}를 방해함")
    @sheet_manager.log_investigation(target_id, location, user_id, "방해받음", false, "#{user_id}에게 방해받음 (다음 판정 -3)")

    # 공개 답글
    @mastodon_client.reply(reply_status, "@#{user_id} @#{target_user}을(를) 방해했습니다!")

    # 방해한 사람 Direct 답글
    @mastodon_client.reply_direct(reply_status, "@#{user_id} @#{target_user}을(를) 방해했습니다!\n다음 조사 판정에 -3 불이익을 줍니다.")

    # 방해받은 사람에게 DM
    @mastodon_client.dm(
      target_id,
      "━━━━━━━━━━━━━━━━━━\n" \
      "방해 경고\n" \
      "━━━━━━━━━━━━━━━━━━\n\n" \
      "@#{user_id}에게 방해를 받았습니다!\n" \
      "다음 조사 판정에 -3 불이익이 적용됩니다.\n" \
      "━━━━━━━━━━━━━━━━━━"
    )
  end

  # === [조사종료]
  def end_investigation(user_id, reply_status)
    @sheet_manager.update_investigation_state(user_id, "없음", "-")
    @mastodon_client.reply_direct(reply_status, "@#{user_id} 조사를 종료했습니다.")
  end
end
