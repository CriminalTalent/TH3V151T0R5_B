require_relative '../core/battle_state'

class GMBattleCommand
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  # [전투목록] / [전투상태]
  def list_battles(reply_status)
    battles = BattleState.all_battles
    
    if battles.empty?
      @mastodon_client.reply(reply_status, "진행 중인 전투가 없습니다.")
      return
    end
    
    msg = "━━━━━━━━━━━━━━━━━━\n"
    msg += "진행 중인 전투 목록\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    
    battles.each_with_index do |(battle_id, state), index|
      elapsed = Time.now - state[:start_time]
      minutes = (elapsed / 60).to_i
      seconds = (elapsed % 60).to_i
      
      type_label = case state[:type]
                   when "1v1" then "[PVP]"
                   when "2v2" then "[2V2]"
                   when "4v4" then "[4V4]"
                   else "[???]"
                   end
      
      participants = state[:participants].join(' ')
      msg += "#{index + 1}. #{type_label} #{participants} (#{minutes}분 #{seconds}초)\n"
      msg += "   현재 턴: #{state[:current_turn]}\n"
      
      if state[:type] != "1v1"
        actions_count = (state[:actions_queue] || []).length
        total_count = state[:participants].length
        msg += "   행동 선택: #{actions_count}/#{total_count}\n"
      end
    end
    
    msg += "━━━━━━━━━━━━━━━━━━"
    
    @mastodon_client.reply(reply_status, msg)
  end

  # [전투종료 battle_id]
  def end_battle(battle_id, reply_status)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.reply(reply_status, "존재하지 않는 전투 ID입니다.")
      return
    end
    
    participants = state[:participants].join(', ')
    BattleState.clear(battle_id)
    
    msg = "전투가 강제 종료되었습니다.\n"
    msg += "전투 ID: #{battle_id}\n"
    msg += "참가자: #{participants}"
    
    @mastodon_client.reply(reply_status, msg)
  end

  # [사용자전투종료 @사용자]
  def end_user_battles(user_id, reply_status)
    battles = BattleState.all_battles
    ended_count = 0
    
    battles.each do |battle_id, state|
      if state[:participants].include?(user_id)
        BattleState.clear(battle_id)
        ended_count += 1
      end
    end
    
    if ended_count > 0
      msg = "#{user_id}님의 전투 #{ended_count}개가 종료되었습니다."
    else
      msg = "#{user_id}님이 참가 중인 전투가 없습니다."
    end
    
    @mastodon_client.reply(reply_status, msg)
  end

  # [전투통계]
  def battle_stats(reply_status)
    battles = BattleState.all_battles
    
    pvp_battles = battles.select { |_, state| state[:type] == "1v1" }
    v2_battles = battles.select { |_, state| state[:type] == "2v2" }
    v4_battles = battles.select { |_, state| state[:type] == "4v4" }
    
    # 평균 시간 계산
    avg_pvp = calculate_average_time(pvp_battles)
    avg_2v2 = calculate_average_time(v2_battles)
    avg_4v4 = calculate_average_time(v4_battles)
    
    # 대기 중인 액션 수
    pending_actions = 0
    battles.each do |_, state|
      if state[:type] != "1v1"
        actions = (state[:actions_queue] || []).length
        expected = state[:participants].length
        pending_actions += (expected - actions) if actions < expected
      end
    end
    
    # 멈춘 전투 (30분 이상 액션 없음)
    stalled_battles = battles.count do |_, state|
      (Time.now - state[:last_action_time]) > 1800
    end
    
    msg = "━━━━━━━━━━━━━━━━━━\n"
    msg += "전투 시스템 통계\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "1:1 전투: #{pvp_battles.length}개 (평균 #{avg_pvp}분)\n"
    msg += "2:2 전투: #{v2_battles.length}개 (평균 #{avg_2v2}분)\n"
    msg += "4:4 전투: #{v4_battles.length}개 (평균 #{avg_4v4}분)\n"
    msg += "대기 중인 액션: #{pending_actions}개\n"
    msg += "멈춘 전투: #{stalled_battles}개\n"
    msg += "━━━━━━━━━━━━━━━━━━"
    
    @mastodon_client.reply(reply_status, msg)
  end

  # [시간초과테스트 battle_id]
  def test_timeout(battle_id, reply_status)
    state = BattleState.get(battle_id)
    
    unless state
      @mastodon_client.reply(reply_status, "존재하지 않는 전투 ID입니다.")
      return
    end
    
    # 시간 체크
    turn_elapsed = Time.now - state[:last_action_time]
    battle_elapsed = Time.now - state[:start_time]
    
    msg = "━━━━━━━━━━━━━━━━━━\n"
    msg += "시간 초과 테스트\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    msg += "전투 ID: #{battle_id}\n"
    msg += "현재 턴: #{state[:current_turn]}\n"
    msg += "턴 경과: #{turn_elapsed.to_i}초 / 240초\n"
    msg += "전투 경과: #{battle_elapsed.to_i}초 / 3600초\n"
    msg += "━━━━━━━━━━━━━━━━━━\n"
    
    if turn_elapsed > 240
      msg += "턴 시간 초과! (자동 방어 대상)\n"
    end
    
    if battle_elapsed > 3600
      msg += "전투 시간 초과! (체력 총합 승부)\n"
    end
    
    @mastodon_client.reply(reply_status, msg)
  end

  private

  def calculate_average_time(battles)
    return 0 if battles.empty?
    
    total_time = battles.sum do |_, state|
      Time.now - state[:start_time]
    end
    
    (total_time / battles.length / 60).to_i
  end
end
