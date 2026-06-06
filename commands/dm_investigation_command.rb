class DMInvestigationCommand
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  def send_result(text, user_id, reply_status)
    match = text.match(/DM조사결과\s+@(\S+)\s+(.+)/i)
    unless match
      @mastodon_client.reply(reply_status, "형식이 올바르지 않습니다. 사용법: DM조사결과 @사용자 결과내용")
      return
    end

    target_username = match[1]
    result_text = match[2]
    
    # @ 제거하고 순수 username만 추출
    clean_username = target_username.gsub('@', '').strip
    
    user = @sheet_manager.find_user(clean_username)
    unless user
      @mastodon_client.reply(reply_status, "#{clean_username}는 등록되지 않은 사용자입니다.")
      return
    end
    
    # 대상에게 DM 전송
    @mastodon_client.dm(clean_username, result_text)
    
    # 조사일 업데이트 (스탯 시트에 "마지막조사일" 컬럼이 있다면)
    today = Time.now.strftime('%Y-%m-%d')
    # update_user를 사용하거나, 컬럼이 없으면 생략
    # @sheet_manager.update_user(clean_username, { last_investigation_date: today })
    
    # 발신자에게 확인 메시지
    @mastodon_client.reply(reply_status, "#{clean_username}에게 조사 결과를 전송했습니다.")
  end
end
