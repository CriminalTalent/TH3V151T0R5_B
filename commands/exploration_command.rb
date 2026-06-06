# commands/exploration_command.rb
# 탐색 명령어 핸들러 (스레드 기반)

require_relative '../core/exploration_system'
require_relative '../core/battle_system'

class ExplorationCommand
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
    @battle_system = BattleSystem.new(mastodon_client, sheet_manager)
  end

  def handle_command(user_id, text, status)
    # 스레드 ID 가져오기
    thread_id = get_thread_id(status)

    case text
    when /\[탐색시작\/(B[2-5])\]/i
      floor = $1.upcase
      start_exploration_solo(user_id, floor, thread_id, status)

    when /\[협력탐색\/(B[2-5])\/((?:@\S+\/)*@\S+)\]/i
      floor = $1.upcase
      participants_text = $2
      participants = participants_text.split('/').map { |p| p.gsub('@', '').strip }.reject(&:empty?)
      start_exploration_coop(user_id, floor, participants, thread_id, status)

    when /\[탐색\]/i
      explore_step(user_id, thread_id, status)

    when /\[전투시작\]/i
      start_encounter_battle(user_id, thread_id, status)

    when /\[탐색종료\]/i
      end_exploration(user_id, thread_id, status)

    when /\[탐색상태\]/i
      show_exploration_status(user_id, thread_id, status)

    else
      nil  # 다른 핸들러로 넘김
    end
  end

  private

  def get_thread_id(status)
    # 스레드 ID: in_reply_to_id가 있으면 그것, 없으면 현재 status id
    status[:in_reply_to_id] || status[:id]
  end

  def start_exploration_solo(user_id, floor, thread_id, status)
    exploration_id = ExplorationSystem.start_exploration(
      [user_id], 
      floor, 
      thread_id,
      sheet_manager: @sheet_manager
    )

    if exploration_id.is_a?(Hash) && exploration_id[:error]
      @mastodon_client.reply(status, exploration_id[:error])
      return
    end

    exploration = ExplorationSystem.get(exploration_id)

    msg = build_start_message(exploration, solo: true)
    @mastodon_client.reply(status, msg)
  end

  def start_exploration_coop(initiator_id, floor, participants, thread_id, status)
    participants << initiator_id unless participants.include?(initiator_id)
    participants.uniq!

    if participants.length > 5
      @mastodon_client.reply(status, "협력 탐색은 최대 5명까지 가능합니다.")
      return
    end

    exploration_id = ExplorationSystem.start_exploration(
      participants, 
      floor, 
      thread_id,
      sheet_manager: @sheet_manager
    )

    if exploration_id.is_a?(Hash) && exploration_id[:error]
      @mastodon_client.reply(status, exploration_id[:error])
      return
    end

    exploration = ExplorationSystem.get(exploration_id)

    msg = build_start_message(exploration, solo: false)
    @mastodon_client.reply_with_mentions(status, msg, participants)
  end

  def explore_step(user_id, thread_id, status)
    exploration = ExplorationSystem.find_by_thread(thread_id)

    unless exploration
      @mastodon_client.reply(status, "이 스레드에서 진행 중인 탐색이 없습니다.")
      return
    end

    result = ExplorationSystem.explore_step(exploration[:exploration_id], user_id)

    if result.is_a?(Hash) && result[:error]
      @mastodon_client.reply(status, result[:error])
      return
    end

    msg = build_step_message(exploration, result, user_id)
    @mastodon_client.reply(status, msg)
  end

  def start_encounter_battle(user_id, thread_id, status)
    exploration = ExplorationSystem.find_by_thread(thread_id)

    unless exploration
      @mastodon_client.reply(status, "이 스레드에서 진행 중인 탐색이 없습니다.")
      return
    end

    battle_data = ExplorationSystem.start_encounter_battle(
      exploration[:exploration_id], 
      user_id
    )

    if battle_data.is_a?(Hash) && battle_data[:error]
      @mastodon_client.reply(status, battle_data[:error])
      return
    end

    # 전투 시스템에 전투 생성
    enemy = battle_data[:enemy]
    participants = battle_data[:participants]

    # 1:1 또는 협력 전투
    if participants.length == 1
      # 1:1 전투
      battle_id = @battle_system.start_pvp(participants.first, 'enemy', enemy_data: enemy)
    else
      # 협력 전투 (팀 vs 적)
      # TODO: 협력 전투 시스템 구현 필요
      @mastodon_client.reply(status, "협력 전투는 각자 [전투시작]으로 참여해주세요.")
      return
    end

    msg = "=" * 40 + "\n"
    msg += "적과 조우!\n"
    msg += "=" * 40 + "\n\n"
    msg += "#{enemy[:full_name]}\n"
    msg += "HP: #{enemy[:hp]} / 공격: #{enemy[:atk]} / 방어: #{enemy[:def]}\n\n"
    msg += "전투가 시작되었습니다!\n"
    msg += "[공격] [방어] [반격] [물약] [도주]"

    @mastodon_client.reply(status, msg)
  end

  def end_exploration(user_id, thread_id, status)
    exploration = ExplorationSystem.find_by_thread(thread_id)

    unless exploration
      @mastodon_client.reply(status, "이 스레드에서 진행 중인 탐색이 없습니다.")
      return
    end

    unless exploration[:participants].include?(user_id)
      @mastodon_client.reply(status, "권한이 없습니다.")
      return
    end

    summary = ExplorationSystem.end_exploration(exploration[:exploration_id])

    msg = build_summary_message(summary)

    if exploration[:participants].length <= 5
      @mastodon_client.reply_with_mentions(status, msg, exploration[:participants])
    else
      @mastodon_client.reply(status, msg)
    end
  end

  def show_exploration_status(user_id, thread_id, status)
    exploration = ExplorationSystem.find_by_thread(thread_id)

    unless exploration
      @mastodon_client.reply(status, "이 스레드에서 진행 중인 탐색이 없습니다.")
      return
    end

    msg = "@#{user_id}\n"
    msg += "=" * 40 + "\n"
    msg += "탐색 상태\n"
    msg += "=" * 40 + "\n\n"
    msg += "장소: #{exploration[:floor_name]}\n"
    msg += "참가자: #{exploration[:participants].length}명\n"
    msg += "진행: #{exploration[:steps]} 걸음\n"
    msg += "현재 위치: #{exploration[:position]}\n\n"
    msg += "발견한 단서: #{exploration[:discovered_clues].size}개\n"
    msg += "획득한 아이템: #{exploration[:found_items].size}개\n"
    msg += "처치한 적: #{exploration[:defeated_enemies].size}명\n\n"

    if exploration[:current_encounter]
      enemy = exploration[:current_encounter]
      msg += "⚠️ 전투 중!\n"
      msg += "적: #{enemy[:full_name]} (HP: #{enemy[:hp]}/#{enemy[:max_hp]})\n\n"
    end

    msg += "명령어: [탐색] [전투시작] [탐색종료] [탐색상태]"

    @mastodon_client.reply(status, msg)
  end

  def build_start_message(exploration, solo:)
    msg = "=" * 40 + "\n"
    msg += "#{exploration[:floor_name]} 탐색 시작\n"
    msg += "=" * 40 + "\n\n"

    if solo
      msg += "개인 탐색 모드\n"
    else
      msg += "협력 탐색 모드 (#{exploration[:participants].length}명)\n"
      msg += exploration[:participants].map { |p| "@#{p}" }.join(', ') + "\n"
    end

    msg += "\n"
    msg += "조사 유형: #{exploration[:investigation_type]}\n"
    msg += "적 조우율: #{exploration[:encounter_rate]}%\n"
    msg += "아이템 발견율: #{exploration[:item_rate]}%\n\n"

    msg += "이곳은 클라리스 오르 조직의 거점입니다.\n"
    msg += "탐색하며 단서를 찾고, 조직원을 처치하세요!\n\n"

    msg += "=" * 40 + "\n\n"

    msg += "명령어:\n"
    msg += "[탐색] - 한 걸음 전진 (단서, 아이템, 적 조우)\n"
    msg += "[전투시작] - 조우한 적과 전투\n"
    msg += "[탐색상태] - 현재 상태 확인\n"
    msg += "[탐색종료] - 탐색 종료\n\n"

    msg += "💡 매일 입구에서 새로 시작합니다!"

    msg
  end

  def build_step_message(exploration, result, user_id)
    player = @sheet_manager.find_user(user_id)
    player_name = player ? (player["이름"] || user_id) : user_id

    msg = "@#{user_id}\n"
    msg += "#{player_name}이(가) 전진합니다... (#{result[:step]} 걸음)\n"
    msg += "위치: #{result[:position]}\n\n"

    if result[:events].empty?
      msg += "조용합니다. 아무것도 발견하지 못했습니다."
      return msg
    end

    result[:events].each do |event|
      case event[:type]
      when 'clue'
        msg += build_clue_message(event[:data])
      when 'item'
        msg += build_item_message(event[:data], user_id)
      when 'encounter'
        msg += build_encounter_message(event[:data])
      end
    end

    msg
  end

  def build_clue_message(clue)
    msg = "=" * 40 + "\n"
    msg += "🔍 단서 발견!\n"
    msg += "=" * 40 + "\n"

    if clue[:is_default]
      msg += clue[:result]
    else
      msg += "대상: #{clue[:target]}\n"
      msg += "판정: #{clue[:dice]} + 행운 #{clue[:luck]} = #{clue[:total]}\n"
      msg += "난이도: #{clue[:difficulty]}\n"
      msg += "결과: #{clue[:success] ? '✅ 성공' : '❌ 실패'}\n\n"
      msg += clue[:result]
    end

    msg += "\n" + "=" * 40 + "\n\n"
    msg
  end

  def build_item_message(item, user_id)
    msg = "=" * 40 + "\n"
    msg += "📦 아이템 발견!\n"
    msg += "=" * 40 + "\n"
    msg += "#{item[:name]}\n"

    # 아이템 지급
    @sheet_manager.add_item(user_id, item[:name])

    msg += "인벤토리에 추가되었습니다.\n"
    msg += "=" * 40 + "\n\n"
    msg
  end

  def build_encounter_message(enemy)
    msg = "=" * 40 + "\n"
    msg += "⚔️ 적 조우!\n"
    msg += "=" * 40 + "\n"
    msg += "#{enemy[:full_name]}\n"
    msg += "HP: #{enemy[:hp]} / 공격: #{enemy[:atk]} / 방어: #{enemy[:def]}\n\n"
    msg += "[전투시작]으로 전투를 시작하세요!\n"
    msg += "=" * 40 + "\n\n"
    msg
  end

  def build_summary_message(summary)
    msg = "=" * 40 + "\n"
    msg += "탐색 종료\n"
    msg += "=" * 40 + "\n\n"
    msg += "장소: #{summary[:floor]}\n"
    msg += "참가자: #{summary[:participants].length}명\n"
    msg += "진행: #{summary[:steps]} 걸음\n"
    msg += "소요 시간: #{summary[:duration]}초\n\n"
    msg += "발견한 단서: #{summary[:clues_found]}개\n"
    msg += "획득한 아이템: #{summary[:items_found]}개\n"
    msg += "처치한 적: #{summary[:enemies_defeated]}명\n\n"
    msg += "수고하셨습니다!"
    msg
  end
end
