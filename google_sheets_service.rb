# google_sheets_service.rb
# SheetManager를 활용한 Google Sheets 서비스
require_relative 'sheet_manager'

class GoogleSheetsService
  def initialize(sheet_id = nil, credentials_path = nil)
    if sheet_id && credentials_path && File.exist?(credentials_path)
      @sheet_manager = SheetManager.new(sheet_id, credentials_path)
      puts "[GoogleSheetsService] Google Sheets 연동 활성화"
    else
      @sheet_manager = nil
      puts "[GoogleSheetsService] 테스트 모드"
    end
  end

  # 탐색 데이터 가져오기
  def get_exploration_data(exploration_id)
    {
      exploration_id: exploration_id,
      participants: [],
      floor: 'B3',
      current_position: 'B3-D8',
      discovered_clues: [],
      found_items: [],
      defeated_enemies: []
    }
  end

  # 플레이어 위치 가져오기 (자동 입력 시트에서)
  def get_player_positions
    return [] unless @sheet_manager
    
    rows = @sheet_manager.read_values("자동 입력!A:F")
    return [] unless rows && rows.length > 1

    positions = []
    rows.each_with_index do |row, idx|
      next if idx == 0  # 헤더 스킵
      next unless row[0] && row[1]  # ID와 현재위치가 있어야 함
      
      user_id = row[0].to_s.gsub('@', '')
      current_position = row[1].to_s.strip
      
      # 좌표 형식 확인 (예: "B3-C4")
      if current_position =~ /^(B[2-5])-([A-H][1-8])$/
        positions << {
          user_id: user_id,
          position: current_position,
          floor: $1
        }
      end
    end

    positions
  rescue => e
    puts "[에러] get_player_positions: #{e.message}"
    []
  end

  # 전체 탐색 목록
  def get_all_explorations
    []
  end

  private

  # 좌표에서 층 추출 (예: "B3-D8" → "B3")
  def extract_floor_from_position(position)
    return nil unless position
    position.to_s.split('-').first
  end
end
