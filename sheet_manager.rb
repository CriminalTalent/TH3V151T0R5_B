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

  # 실행 시트: 1행=헤더, 2행=데이터 (A=ON/OFF, B=라운드, C=턴)
  def read_trigger
    rows = read("실행!A2:C2")
    return nil if rows.empty?
    row = rows[0]
    {
      on: row[0].to_s.upcase == 'TRUE',
      round: row[1].to_i,
      turn: row[2].to_i
    }
  end

  def turn_off_trigger
    write("실행!A2", [['FALSE']])
  end

  # 보정 시트: 1행=헤더, 2행~=데이터 (A=이름, B=항목, C=값, D=적용여부, E=메모)
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
    updates = rows.map { |r| r[3].to_s.upcase == 'TRUE' ? [r[0], r[1], r[2], 'FALSE', r[4]] : r }
    body = Google::Apis::SheetsV4::ValueRange.new(values: updates)
    @service.update_spreadsheet_value(@sheet_id, "보정!A2:E#{updates.size + 1}", body, value_input_option: 'RAW')
  rescue => e
    puts "[Sheet 오류] clear_corrections: #{e.message}"
  end

  # 운영 시트 스탯 탭: A=캐릭터명, B=건강, C=마법능력, D=내구도, E=민첩, F=기술, G=행운, H=스킬1, I=스킬2
  def read_base_stats
    rows = read("스탯!A2:I30")
    rows.map do |r|
      {
        name:   r[0].to_s.strip,
        hp:     r[1].to_i,
        atk:    r[2].to_i,
        dur:    r[3].to_i,
        agi:    r[4].to_i,
        tec:    r[5].to_i,
        luck:   r[6].to_i,
        skill1: r[7].to_s.strip,
        skill2: r[8].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # 러너 커맨드 시트 - 현상태: A=캐릭터명, B=현재건강, C=현재위치 (1행~)
  def read_current_state
    rows = read("현황!A1:C30")
    rows.map do |r|
      {
        name: r[0].to_s.strip,
        hp:   r[1].to_i,
        pos:  r[2].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # 러너 커맨드 시트 - 커맨드: A=캐릭터명, B=이동위치, C=행동, D=대상1, E=대상2, F=대상3, G=대상4, H=대상5
  def read_commands
    rows = read("커맨드!A1:H30")
    rows.map do |r|
      {
        name:       r[0].to_s.strip,
        move_to:    r[1].to_s.strip,
        action:     r[2].to_s.strip,
        targets:    [r[3], r[4], r[5], r[6], r[7]].map { |t| t.to_s.strip }.reject(&:empty?),
        target_pos: '',
        extra:      ''
      }
    end.reject { |r| r[:name].empty? }
  end

  # 운영 시트 스킬 탭: A=스킬명, B=분류, C=사거리, D=쿨타임, E=설명
  def read_skill_data
    rows = read("스킬!A2:E50")
    rows.map do |r|
      {
        name:    r[0].to_s.strip,
        type:    r[1].to_s.strip,
        range:   r[2].to_s.strip,
        cooldown: r[3].to_s.strip,
        desc:    r[4].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  # 현상태 업데이트 (러너 커맨드 시트 현황 탭)
  def update_current_state(states)
    values = states.map { |s| [s[:name], s[:hp], s[:pos]] }
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @service.update_spreadsheet_value(
      @sheet_id, "현황!A1:C#{values.size}",
      body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] update_current_state: #{e.message}"
  end
end
