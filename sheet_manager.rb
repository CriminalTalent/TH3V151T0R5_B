# sheet_manager.rb
require 'google/apis/sheets_v4'
require 'googleauth'
require 'json'

class SheetManager
  # 스탯 시트 열 구조
  # A: ID, B: 이름, C: HP, D: 체력, E: 공격력, F: 방어력, G: 속도, H: 기술, I: 행운, J: 행동력

  STAT_COLS = {
    "HP"   => "C",
    "체력"  => "D",
    "공격력" => "E",
    "방어력" => "F",
    "속도"  => "G",
    "기술"  => "H",
    "행운"  => "I",
    "행동력" => "J"
  }.freeze

  STAT_RANGE = "'스탯'!A2:J1000".freeze

  def initialize
    @spreadsheet_id   = ENV['GOOGLE_SHEET_ID']
    @credentials_path = ENV['GOOGLE_CREDENTIALS_PATH'] || 'credentials.json'
    @sheets_service   = Google::Apis::SheetsV4::SheetsService.new
    @sheets_service.authorization = authorize
    @mutex = Mutex.new
    puts "[SheetManager] 초기화 완료"
  end

  private

  def authorize
    scope = Google::Apis::SheetsV4::AUTH_SPREADSHEETS
    authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: File.open(@credentials_path),
      scope: scope
    )
    authorizer.fetch_access_token!
    authorizer
  end

  public

  def find_user(user_id)
    @mutex.synchronize do
      begin
        stats_values = @sheets_service.get_spreadsheet_values(@spreadsheet_id, STAT_RANGE).values
        return nil unless stats_values

        stats_row = stats_values.find { |row| row[0] == user_id }
        return nil unless stats_row

        user_range  = "'사용자'!A2:F1000"
        user_values = @sheets_service.get_spreadsheet_values(@spreadsheet_id, user_range).values
        user_row    = user_values&.find { |row| row[0] == user_id }

        {
          "ID"   => stats_row[0],
          "이름" => stats_row[1] || user_id,
          "HP"   => (stats_row[2] || "500").to_i,   # C
          "체력"  => (stats_row[3] || "50").to_i,    # D
          "공격력" => (stats_row[4] || "10").to_i,   # E
          "방어력" => (stats_row[5] || "10").to_i,   # F
          "속도"  => (stats_row[6] || "0").to_i,     # G
          "기술"  => (stats_row[7] || "0").to_i,     # H
          "행운"  => (stats_row[8] || "5").to_i,     # I
          "행동력" => (stats_row[9] || "5").to_i,    # J
          "갈레온" => user_row ? (user_row[2] || "0").to_i : 0,
          "아이템" => user_row ? (user_row[3] || "") : "",
          "기숙사" => user_row ? (user_row[5] || "") : ""
        }
      rescue => e
        puts "[SheetManager] 사용자 검색 오류: #{e.message}"
        nil
      end
    end
  end

  def update_user(user_id, updates)
    @mutex.synchronize do
      begin
        stats_values = @sheets_service.get_spreadsheet_values(@spreadsheet_id, STAT_RANGE).values
        return false unless stats_values

        row_index = stats_values.find_index { |row| row[0] == user_id }
        return false unless row_index

        actual_row    = row_index + 2
        stats_updates = {}
        user_updates  = {}

        updates.each do |key, value|
          col = STAT_COLS[key.to_s]
          if col
            stats_updates[col] = value
          elsif key.to_s == "갈레온"
            user_updates["C"] = value
          elsif key.to_s == "아이템"
            user_updates["D"] = value
          end
        end

        stats_updates.each do |col, value|
          vr = Google::Apis::SheetsV4::ValueRange.new(values: [[value]])
          @sheets_service.update_spreadsheet_value(
            @spreadsheet_id, "'스탯'!#{col}#{actual_row}", vr,
            value_input_option: 'USER_ENTERED'
          )
        end

        if user_updates.any?
          user_values = @sheets_service.get_spreadsheet_values(@spreadsheet_id, "'사용자'!A2:F1000").values
          if user_values
            u_idx = user_values.find_index { |row| row[0] == user_id }
            if u_idx
              u_row = u_idx + 2
              user_updates.each do |col, value|
                vr = Google::Apis::SheetsV4::ValueRange.new(values: [[value]])
                @sheets_service.update_spreadsheet_value(
                  @spreadsheet_id, "'사용자'!#{col}#{u_row}", vr,
                  value_input_option: 'USER_ENTERED'
                )
              end
            end
          end
        end

        true
      rescue => e
        puts "[SheetManager] 업데이트 오류: #{e.message}"
        false
      end
    end
  end

  def all_users
    @mutex.synchronize do
      begin
        stats_values = @sheets_service.get_spreadsheet_values(@spreadsheet_id, STAT_RANGE).values
        return [] unless stats_values

        user_values = @sheets_service.get_spreadsheet_values(@spreadsheet_id, "'사용자'!A2:F1000").values

        stats_values.map do |r|
          next unless r[0]
          ur = user_values&.find { |row| row[0] == r[0] }
          {
            "ID"   => r[0],
            "이름" => r[1] || r[0],
            "HP"   => (r[2] || "500").to_i,
            "체력"  => (r[3] || "50").to_i,
            "공격력" => (r[4] || "10").to_i,
            "방어력" => (r[5] || "10").to_i,
            "속도"  => (r[6] || "0").to_i,
            "기술"  => (r[7] || "0").to_i,
            "행운"  => (r[8] || "5").to_i,
            "행동력" => (r[9] || "5").to_i,
            "갈레온" => ur ? (ur[2] || "0").to_i : 0,
            "아이템" => ur ? (ur[3] || "") : "",
            "기숙사" => ur ? (ur[5] || "") : ""
          }
        end.compact
      rescue => e
        puts "[SheetManager] 사용자 목록 오류: #{e.message}"
        []
      end
    end
  end

  def user_exists?(user_id)
    !find_user(user_id).nil?
  end

  def read_values(range)
    @sheets_service.get_spreadsheet_values(@spreadsheet_id, range).values
  rescue => e
    puts "[SheetManager] read_values 오류: #{e.message}"
    nil
  end

  def read(sheet_name, range)
    read_values("#{sheet_name}!#{range}") || []
  end

  def append(sheet_name, row)
    vr = Google::Apis::SheetsV4::ValueRange.new(values: [row])
    @sheets_service.append_spreadsheet_value(
      @spreadsheet_id, "#{sheet_name}!A:A", vr,
      value_input_option: 'USER_ENTERED',
      insert_data_option: 'INSERT_ROWS'
    )
  rescue => e
    puts "[SheetManager] append 오류: #{e.message}"
  end

  def update_values(range, values)
    vr = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @sheets_service.update_spreadsheet_value(
      @spreadsheet_id, range, vr,
      value_input_option: 'USER_ENTERED'
    )
  rescue => e
    puts "[SheetManager] update_values 오류: #{e.message}"
  end

  def write(sheet_name, range, values)
    update_values("#{sheet_name}!#{range}", values)
  end

  def append_values(range, values)
    vr = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @sheets_service.append_spreadsheet_value(
      @spreadsheet_id, range, vr,
      value_input_option: 'USER_ENTERED',
      insert_data_option: 'INSERT_ROWS'
    )
  rescue => e
    puts "[SheetManager] append_values 오류: #{e.message}"
  end
end
