require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  SCOPE = Google::Apis::SheetsV4::AUTH_SPREADSHEETS

  def initialize(sheet_id, credentials_path)
    @sheet_id = sheet_id
    @service = Google::Apis::SheetsV4::SheetsService.new
    @service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: File.open(credentials_path),
      scope: SCOPE
    )
    @service.authorization.fetch_access_token!
  end

  def read(range)
    @service.get_spreadsheet_values(@sheet_id, range).values || []
  rescue => e
    puts "[Sheet 오류] read #{range}: #{e.message}"
    []
  end

  def write(range, values)
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @service.update_spreadsheet_value(@sheet_id, range, body, value_input_option: 'RAW')
  rescue => e
    puts "[Sheet 오류] write #{range}: #{e.message}"
  end

  # 실행 시트: A1(ON/OFF), B1(라운드), C1(턴)
  def read_trigger
    rows = read("실행!A1:C1")
    return nil if rows.empty?
    row = rows[0]
    {
      on: row[0].to_s.upcase == 'TRUE',
      round: row[1].to_i,
      turn: row[2].to_i  # 1=선공, 2=후공
    }
  end

  def turn_off_trigger
    write("실행!A1", [['FALSE']])
  end

  # 보정 시트: A(이름), B(항목), C(값), D(적용여부), E(메모)
  def read_corrections
    rows = read("보정!A2:E50")
    rows.select { |r| r[3].to_s.upcase == 'TRUE' }.map do |r|
      {
        name: r[0].to_s.strip,
        type: r[1].to_s.strip,
        value: r[2].to_s.strip,
        memo: r[4].to_s.strip
      }
    end
  end

  def clear_corrections
    rows = read("보정!A2:E50")
    return if rows.empty?
    updates = rows.each_with_index.map do |r, i|
      next if r[3].to_s.upcase != 'TRUE'
      [r[0], r[1], r[2], 'FALSE', r[4]]
    end.compact
    return if updates.empty?
    body = Google::Apis::SheetsV4::ValueRange.new(values: updates)
    @service.update_spreadsheet_value(@sheet_id, "보정!A2:E#{updates.size + 1}", body, value_input_option: 'RAW')
  rescue => e
    puts "[Sheet 오류] clear_corrections: #{e.message}"
  end

  # DATA 시트 - 기본 스탯 (4행~, B=이름 C=체력 D=공격력 E=방어력 F=속도 G=기술 H=스킬1 I=스킬2 J=스킬3 K=특수)
  def read_base_stats
    rows = read("DATA!B4:K10")
    rows.map do |r|
      {
        name: r[0].to_s.strip,
        hp: r[1].to_i,
        atk: r[2].to_i,
        def: r[3].to_i,
        spd: r[4].to_i,
        tec: r[5].to_i,
        skill1: r[6].to_s.strip,
        skill2: r[7].to_s.strip,
        skill3: r[8].to_s.strip,
        special: r[9].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # DATA 시트 - 현상태 (13행~, B=이름 C=현재체력 D=현재행동력 E=현재위치 F=적위치 G=적군이름)
  def read_current_state
    rows = read("DATA!B13:G20")
    rows.map do |r|
      {
        name: r[0].to_s.strip,
        hp: r[1].to_i,
        ap: r[2].to_i,
        pos: r[3].to_s.strip,
        enemy_pos: r[4].to_s.strip,
        enemy_name: r[5].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # DATA 시트 - 러너 커맨드 (23행~, B=이름 C=이동위치 D=사용행동 E=대상1 F=대상2 G=대상3 H=대상4 I=대상5 J=대상1위치지정)
  def read_commands
    rows = read("DATA!B23:J30")
    rows.map do |r|
      {
        name: r[0].to_s.strip,
        move_to: r[1].to_s.strip,
        action: r[2].to_s.strip,
        targets: [r[3], r[4], r[5], r[6], r[7]].map { |t| t.to_s.strip }.reject(&:empty?),
        target_pos: r[8].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # DATA 시트 - 스킬 데이터 (34행~, B=스킬명 C=분류 D=사거리 E=소모행동력 F=설명)
  def read_skill_data
    rows = read("DATA!B34:F60")
    rows.map do |r|
      {
        name: r[0].to_s.strip,
        type: r[1].to_s.strip,
        range: r[2].to_s.strip,
        cost: r[3].to_i,
        desc: r[4].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # 현상태 업데이트 (현상태 결과 받음 테이블)
  def update_current_state(states)
    # B~E열: 이름, 현재체력, 현재행동력, 현재위치 (13행~)
    values = states.map { |s| [s[:name], s[:hp], s[:ap], s[:pos]] }
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @service.update_spreadsheet_value(
      @sheet_id, "DATA!B13:E#{13 + values.size - 1}",
      body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] update_current_state: #{e.message}"
  end
end
