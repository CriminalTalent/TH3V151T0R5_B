require_relative 'commands/battle_command'
require_relative 'commands/potion_command'
require_relative 'commands/heal_command'
require_relative 'commands/hp_command'
require_relative 'commands/gm_battle_command'

class CommandParser
  GM_ACCOUNTS = ['Story', 'professor', 'Store', 'FortunaeFons'].freeze

  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
    @battle_command = BattleCommand.new(mastodon_client, sheet_manager)
    @potion_command = PotionCommand.new(mastodon_client, sheet_manager)
    @heal_command = HealCommand.new(mastodon_client, sheet_manager)
    @hp_command = HpCommand.new(mastodon_client, sheet_manager)
    @gm_battle_command = GMBattleCommand.new(mastodon_client, sheet_manager)
    puts "[파서] 초기화 완료"
  end

  def handle(status)
    content = status[:content]
    text = content.gsub(/<[^>]+>/, '').strip
    user_id = status[:account][:acct]
    parse(text, user_id, status)
  end

  def parse(text, user_id, reply_status)
    text = text.strip
    
    puts "[전투봇] 명령 수신: #{text} (from @#{user_id})"

    # 평상시 물약 사용 - [물약/크기]
    if text =~ /\[물약\/(소형|중형|대형)\]/i
      potion_type = $1
      @potion_command.use_potion(user_id, reply_status, potion_type)
      return
    end

    # GM 명령어들
    if GM_ACCOUNTS.include?(user_id)
      # [전투목록] / [전투상태]
      if text =~ /\[전투(?:목록|상태)\]/i
        @gm_battle_command.list_battles(reply_status)
        return
      end

      # [전투종료 battle_id]
      if text =~ /\[전투종료\s+(\w+)\]/i
        battle_id = $1
        @gm_battle_command.end_battle(battle_id, reply_status)
        return
      end

      # [사용자전투종료 @사용자]
      if text =~ /\[사용자전투종료\s+@?(\w+)\]/i
        user = $1
        @gm_battle_command.end_user_battles(user, reply_status)
        return
      end

      # [전투통계]
      if text =~ /\[전투통계\]/i
        @gm_battle_command.battle_stats(reply_status)
        return
      end

      # [시간초과테스트 battle_id]
      if text =~ /\[시간초과테스트\s+(\w+)\]/i
        battle_id = $1
        @gm_battle_command.test_timeout(battle_id, reply_status)
        return
      end

      # [전투중단/@A/@B...] - GM 전투 중단
      if text =~ /\[전투중단((?:\/@?\w+)+)\]/i
        participants_text = $1
        participants = participants_text.split('/').map { |p| p.gsub('@', '').strip }.reject(&:empty?)
        handle_gm_end_battle(user_id, participants, reply_status)
        return
      end
    end

    # 체력 확인 - [체력] 또는 [HP]
    if text =~ /\[(?:체력|HP)\]/i
      @hp_command.check_hp(user_id, reply_status)
      return
    end

    # 1:1 전투 개시 - [전투/@상대]
    if text =~ /\[전투\/(@?\w+)\]$/i
      target = $1.gsub('@', '').strip
      
      if GM_ACCOUNTS.include?(user_id)
        @mastodon_client.reply(reply_status, "GM은 [전투/@A/@B] 형식으로 두 플레이어를 지정해야 합니다.")
        return
      end
      
      @battle_command.start_1v1(user_id, target, reply_status)
      return
    end

    # GM 1:1 전투 개시 - [전투/@A/@B]
    if text =~ /\[전투\/(@?\w+)\/(@?\w+)\]$/i
      unless GM_ACCOUNTS.include?(user_id)
        @mastodon_client.reply(reply_status, "일반 사용자는 [전투/@상대] 형식을 사용하세요.")
        return
      end
      
      player1 = $1.gsub('@', '').strip
      player2 = $2.gsub('@', '').strip
      @battle_command.start_1v1(player1, player2, reply_status)
      return
    end

    # 2:2 전투 개시 - [팀전투/@A/@B/@C/@D]
    if text =~ /\[팀전투((?:\/@?\w+){4})\]/i
      participants_text = $1
      participants = participants_text.split('/').map { |p| p.gsub('@', '').strip }.reject(&:empty?)
      
      if participants.length != 4
        @mastodon_client.reply(reply_status, "팀전투는 정확히 4명이 필요합니다.")
        return
      end
      
      unless GM_ACCOUNTS.include?(user_id) || participants.include?(user_id)
        @mastodon_client.reply(reply_status, "본인이 참가자에 포함되거나 GM이어야 합니다.")
        return
      end
      
      @battle_command.start_2v2(participants[0], participants[1], participants[2], participants[3], reply_status)
      return
    end

    # 4:4 전투 개시 - [대규모전투/@A/@B/@C/@D/@E/@F/@G/@H]
    if text =~ /\[대규모전투((?:\/@?\w+){8})\]/i
      participants_text = $1
      participants = participants_text.split('/').map { |p| p.gsub('@', '').strip }.reject(&:empty?)
      
      if participants.length != 8
        @mastodon_client.reply(reply_status, "대규모전투는 정확히 8명이 필요합니다.")
        return
      end
      
      unless GM_ACCOUNTS.include?(user_id) || participants.include?(user_id)
        @mastodon_client.reply(reply_status, "본인이 참가자에 포함되거나 GM이어야 합니다.")
        return
      end
      
      @battle_command.start_4v4(participants[0], participants[1], participants[2], participants[3],
                                participants[4], participants[5], participants[6], participants[7], reply_status)
      return
    end

    # 전투 중 공격 - [공격] 또는 [공격/@타겟]
    if text =~ /\[공격(?:\/(@?\w+))?\]/i
      target = $1 ? $1.gsub('@', '').strip : nil
      @battle_command.attack(user_id, target, reply_status)
      return
    end

    # 전투 중 방어 - [방어] 또는 [방어/@타겟]
    if text =~ /\[방어(?:\/(@?\w+))?\]/i
      target = $1 ? $1.gsub('@', '').strip : nil
      @battle_command.defend(user_id, target, reply_status)
      return
    end

    # 전투 중 반격 - [반격]
    if text =~ /\[반격\]/i
      @battle_command.counter(user_id, reply_status)
      return
    end

    # 전투 중 물약 사용 - [물약사용/크기] 또는 [물약사용/크기/@타겟]
    if text =~ /\[물약사용\/(소형|중형|대형)(?:\/(@?\w+))?\]/i
      potion_type = $1
      target = $2 ? $2.gsub('@', '').strip : nil
      
      if target
        @potion_command.use_potion_for_target(user_id, reply_status, potion_type, target)
      else
        @potion_command.use_potion(user_id, reply_status, potion_type)
      end
      return
    end

    puts "[무시] 인식되지 않은 명령: #{text}"

  rescue => e
    puts "[에러] CommandParser 오류: #{e.message}"
    puts e.backtrace.first(5)
    @mastodon_client.reply(reply_status, "@#{user_id} 명령 처리 중 오류가 발생했습니다.")
  end

  private

  def handle_gm_end_battle(gm_id, participants, reply_status)
    require_relative 'core/battle_state'
    
    battle_id = BattleState.find_battle_by_participants(participants)
    
    if battle_id
      battle = BattleState.get(battle_id)
      BattleState.clear(battle_id)
      
      msg = "#{gm_id}님이 전투를 중단했습니다.\n"
      msg += "참가자: #{participants.join(', ')}"
      
      @mastodon_client.reply(reply_status, msg)
    else
      @mastodon_client.reply(reply_status, "해당 참가자들의 전투를 찾을 수 없습니다.")
    end
  end
end
