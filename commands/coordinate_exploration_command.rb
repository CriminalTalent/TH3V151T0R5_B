# commands/coordinate_exploration_command.rb
# 좌표 기반 탐색 명령어 핸들러

require_relative '../core/coordinate_exploration_system'

class CoordinateExplorationCommand
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end

  # ===========================
  # 개인 탐색 시작
  # ===========================
  def start_exploration(user_id, floor, reply_status)
    # 맵 데이터 로드
    floor_data = CoordinateExplorationSystem.get_floor_data(floor)
    unless floor_data
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ #{floor}층 맵 데이터를 찾을 수 없습니다.")
      return
    end

    # 탐색 생성
    exploration = CoordinateExplorationSystem.create_exploration(
      floor: floor,
      participants: [user_id]
    )

    # 입구 좌표
    entrance = floor_data["entrance"]
    
    # Google Sheets에 초기 위치 기록
    update_player_location_in_sheets(user_id, entrance)
    
    @mastodon_client.reply(reply_status, <<~MSG.strip)
      @#{user_id}
      ========================================
      #{floor_data["name"]} 탐색 시작
      ========================================
      
      난이도: #{floor_data["difficulty"]}
      조사 유형: #{floor_data["investigation_type"]}
      입구: #{entrance}
      
      ========================================
      [좌표이동/좌표], [좌표조사], [좌표맵], [좌표종료] 명령어를 사용하세요.
    MSG
  end

  # ===========================
  # 협력 탐색 시작
  # ===========================
  def start_cooperative(initiator, floor, participants, reply_status)
    # 맵 데이터 로드
    floor_data = CoordinateExplorationSystem.get_floor_data(floor)
    unless floor_data
      @mastodon_client.reply(reply_status, "@#{initiator}\n❌ #{floor}층 맵 데이터를 찾을 수 없습니다.")
      return
    end

    # 최대 5명 제한
    if participants.length > 5
      @mastodon_client.reply(reply_status, "@#{initiator}\n❌ 협력 탐색은 최대 5명까지 가능합니다. (현재: #{participants.length}명)")
      return
    end

    # 개시자를 참가자 목록에 추가 (중복 방지)
    all_participants = ([initiator] + participants).uniq

    # 탐색 생성
    exploration = CoordinateExplorationSystem.create_exploration(
      floor: floor,
      participants: all_participants
    )

    entrance = floor_data["entrance"]
    
    # 모든 참가자 초기 위치 기록
    all_participants.each do |participant|
      update_player_location_in_sheets(participant, entrance)
    end
    
    mentions = all_participants.map { |p| "@#{p}" }.join(' ')
    
    @mastodon_client.reply(reply_status, <<~MSG.strip)
      #{mentions}
      ========================================
      #{floor_data["name"]} 협력 탐색 시작
      ========================================
      
      난이도: #{floor_data["difficulty"]}
      조사 유형: #{floor_data["investigation_type"]}
      
      참가자: #{all_participants.join(', ')}
      입구: #{entrance}
      
      ========================================
      각자 [좌표이동/좌표], [좌표조사] 명령어로 탐색하세요.
      [좌표맵]으로 맵을 확인할 수 있습니다.
    MSG
  end

  # ===========================
  # 좌표로 이동
  # ===========================
  def move_to(user_id, floor, coord, reply_status)
    # 활성 탐색 찾기
    exploration = CoordinateExplorationSystem.find_active_exploration(user_id)
    unless exploration
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 진행 중인 탐색이 없습니다. [좌표탐색/층] 명령어로 시작하세요.")
      return
    end

    # 층 확인
    if exploration[:floor] != floor.upcase
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ #{floor}층이 아닌 #{exploration[:floor]}층을 탐색 중입니다.")
      return
    end

    full_coord = "#{floor}-#{coord}"

    # 맵 데이터 로드
    floor_data = CoordinateExplorationSystem.get_floor_data(floor)
    
    unless floor_data
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 맵 데이터를 찾을 수 없습니다.")
      return
    end
    
    tile = floor_data["grid"][full_coord]

    unless tile
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ #{full_coord} 좌표가 존재하지 않습니다.")
      return
    end

    # 벽 체크
    if tile["type"] == "wall"
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ #{full_coord}는 벽입니다. 이동할 수 없습니다.")
      return
    end

    # 위치 업데이트 (메모리)
    CoordinateExplorationSystem.update_player_position(exploration[:exploration_id], user_id, full_coord)

    # Google Sheets 업데이트 (위치 시트)
    update_player_location_in_sheets(user_id, full_coord)

    @mastodon_client.reply(reply_status, <<~MSG.strip)
      @#{user_id}
      ========================================
      이동 완료
      ========================================
      
      #{full_coord} (#{tile["name"]})
      
      타입: #{tile["type"] == "corridor" ? "복도" : tile["type"] == "room" ? "방" : tile["type"] == "entrance" ? "입구" : "?"}
      
      ========================================
      [좌표조사]로 조사하거나 [좌표맵]으로 맵을 확인하세요.
    MSG
  end

  # ===========================
  # 현재 위치 조사
  # ===========================
  def investigate_current(user_id, reply_status)
    # 활성 탐색 찾기
    exploration = CoordinateExplorationSystem.find_active_exploration(user_id)
    unless exploration
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 진행 중인 탐색이 없습니다.")
      return
    end

    # 현재 위치
    current_position = exploration[:player_positions][user_id]
    unless current_position
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 현재 위치를 알 수 없습니다. [좌표이동/좌표]로 이동하세요.")
      return
    end

    floor_data = CoordinateExplorationSystem.get_floor_data(exploration[:floor])
    tile = floor_data["grid"][current_position]

    location_name = tile["name"]
    investigation_type = exploration[:investigation_type]

    # 조사 시트에서 데이터 찾기
    entry = @sheet_manager.find_investigation_entry(location_name, investigation_type)

    unless entry
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ '#{location_name}'에 대한 #{investigation_type} 데이터가 없습니다.")
      return
    end

    # 플레이어 정보
    player = @sheet_manager.find_user(user_id)
    unless player
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 플레이어 정보를 찾을 수 없습니다.")
      return
    end

    # 판정
    dice = rand(1..20)
    luck = player["행운"].to_i
    total = dice + luck
    difficulty = entry[:difficulty].to_i
    success = total >= difficulty

    result_text = success ? entry[:success_output] : entry[:failure_output]

    # 보상 처리
    rewards = process_rewards(user_id, result_text) if success

    # 로그 기록
    @sheet_manager.log_investigation(
      user_id,
      exploration[:floor],
      location_name,
      investigation_type,
      success,
      result_text
    )

    # 응답
    result_emoji = success ? "✅" : "❌"
    
    msg = <<~MSG.strip
      @#{user_id}
      ========================================
      #{location_name} 조사
      ========================================
      
      판정: #{dice} + 행운 #{luck} = #{total}
      난이도: #{difficulty}
      결과: #{result_emoji} #{success ? "성공" : "실패"}
      
      ========================================
      #{result_text}
      
      ========================================
    MSG

    if success && rewards
      msg += "\n획득:\n"
      rewards.each do |reward|
        msg += "• #{reward}\n"
      end
      msg += "========================================"
    end

    @mastodon_client.reply(reply_status, msg)
  end

  # ===========================
  # 탐색 상태 확인
  # ===========================
  def show_status(user_id, reply_status)
    exploration = CoordinateExplorationSystem.find_active_exploration(user_id)
    unless exploration
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 진행 중인 탐색이 없습니다.")
      return
    end

    current_pos = exploration[:player_positions][user_id] || "알 수 없음"
    
    @mastodon_client.reply(reply_status, <<~MSG.strip)
      @#{user_id}
      ========================================
      탐색 상태
      ========================================
      
      층: #{exploration[:floor_name]}
      현재 위치: #{current_pos}
      
      참가자: #{exploration[:participants].join(', ')}
      
      발견한 단서: #{exploration[:discovered_clues].length}개
      획득한 아이템: #{exploration[:found_items].length}개
      처치한 적: #{exploration[:defeated_enemies].length}마리
      
      ========================================
    MSG
  end

  # ===========================
  # ASCII 맵 출력
  # ===========================
  def show_map(user_id, reply_status)
    exploration = CoordinateExplorationSystem.find_active_exploration(user_id)
    unless exploration
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 진행 중인 탐색이 없습니다.")
      return
    end

    floor_data = CoordinateExplorationSystem.get_floor_data(exploration[:floor])
    map_ascii = render_ascii_map(floor_data, exploration)

    @mastodon_client.reply(reply_status, <<~MSG.strip)
      @#{user_id}
      ========================================
      #{exploration[:floor_name]}
      ========================================
      
      #{map_ascii}
      
      ■ 벽 | · 복도 | □ 방 | ○ 입구 | ● 플레이어
      ========================================
    MSG
  end

  # ===========================
  # 탐색 종료
  # ===========================
  def end_exploration(user_id, reply_status)
    exploration = CoordinateExplorationSystem.find_active_exploration(user_id)
    unless exploration
      @mastodon_client.reply(reply_status, "@#{user_id}\n❌ 진행 중인 탐색이 없습니다.")
      return
    end

    CoordinateExplorationSystem.delete_exploration(exploration[:exploration_id])

    @mastodon_client.reply(reply_status, <<~MSG.strip)
      @#{user_id}
      ========================================
      탐색 종료
      ========================================
      
      #{exploration[:floor_name]} 탐색이 종료되었습니다.
      
      발견한 단서: #{exploration[:discovered_clues].length}개
      획득한 아이템: #{exploration[:found_items].length}개
      처치한 적: #{exploration[:defeated_enemies].length}마리
      
      ========================================
      수고하셨습니다!
    MSG
  end

  private

  # ===========================
  # Google Sheets 위치 업데이트
  # ===========================
  def update_player_location_in_sheets(user_id, coord)
    begin
      # 위치 시트에서 유저 찾기
      rows = @sheet_manager.read_values("위치!A:F")
      return unless rows && rows.length > 1

      headers = rows[0]
      user_row_index = nil
      current_location = nil

      rows.each_with_index do |row, idx|
        next if idx == 0
        if row[0]&.gsub('@', '') == user_id.gsub('@', '')
          user_row_index = idx + 1
          current_location = row[1] # 현재위치
          break
        end
      end

      # 유저가 시트에 없으면 새로 추가
      unless user_row_index
        @sheet_manager.append_values("위치!A:F", [
          [user_id, coord, "", Time.now.strftime('%Y-%m-%d %H:%M:%S'), 0, 3]
        ])
        return
      end

      # 기존 유저면 업데이트
      @sheet_manager.update_values("위치!B#{user_row_index}:D#{user_row_index}", [
        [coord, current_location || "", Time.now.strftime('%Y-%m-%d %H:%M:%S')]
      ])
    rescue => e
      puts "[에러] Google Sheets 위치 업데이트 실패: #{e.message}"
    end
  end

  # ===========================
  # 보상 처리
  # ===========================
  def process_rewards(user_id, result_text)
    rewards = []

    # [아이템:아이템명] 파싱
    result_text.scan(/\[아이템:([^\]]+)\]/) do |item_name|
      item_name = item_name[0].strip
      @sheet_manager.update_user(user_id, items: [item_name])
      rewards << "아이템: #{item_name}"
    end

    # [갈레온:숫자] 파싱
    result_text.scan(/\[갈레온:(\d+)\]/) do |amount|
      amount = amount[0].to_i
      player = @sheet_manager.find_user(user_id)
      current_galleons = player["갈레온"].to_i
      new_galleons = current_galleons + amount
      @sheet_manager.update_user_items(user_id, galleons: new_galleons)
      rewards << "갈레온: +#{amount}G (총 #{new_galleons}G)"
    end

    rewards.empty? ? nil : rewards
  end

  # ===========================
  # ASCII 맵 렌더링
  # ===========================
  def render_ascii_map(floor_data, exploration)
    lines = []
    
    # 헤더
    lines << "   A B C D E F G H"
    
    # 행별 렌더링
    (1..8).each do |row|
      row_chars = [row.to_s.rjust(2)]
      
      ('A'..'H').each do |col|
        coord = "#{exploration[:floor]}-#{col}#{row}"
        tile = floor_data["grid"][coord]
        
        # 플레이어 위치 확인
        has_player = exploration[:player_positions].values.include?(coord)
        
        if has_player
          row_chars << '●'
        elsif tile
          case tile["type"]
          when "wall"
            row_chars << '■'
          when "corridor"
            row_chars << '·'
          when "room"
            row_chars << '□'
          when "entrance"
            row_chars << '○'
          else
            row_chars << '?'
          end
        else
          row_chars << '?'
        end
      end
      
      lines << row_chars.join(' ')
    end
    
    lines.join("\n")
  end
end
