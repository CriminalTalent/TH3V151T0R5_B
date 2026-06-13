require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  SCOPE = Google::Apis::SheetsV4::AUTH_SPREADSHEETS

  def initialize(sheet_id, credentials_path)
    @sheet_id = sheet_id
    @service  = Google::Apis::SheetsV4::SheetsService.new
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

  def read_trigger
    rows = read("실행!A2:D2")
    return nil if rows.empty?
    row = rows[0]
    {
      on:    row[0].to_s.upcase == 'TRUE',
      round: row[1].to_i,
      team:  row[2].to_s.strip,
      first: row[3].to_s.strip == '선공'
    }
  end

  def turn_off_trigger
    write("실행!A2", [['FALSE']])
  end

  def read_corrections
    rows = read("보정!A2:E50")
    rows.select { |r| r[3].to_s.upcase == 'TRUE' }.map do |r|
      { name: r[0].to_s.strip, type: r[1].to_s.strip,
        value: r[2].to_s.strip, memo: r[4].to_s.strip }
    end
  end

  def clear_corrections
    rows = read("보정!A2:E50")
    return if rows.empty?
    updates = rows.map do |r|
      r[3].to_s.upcase == 'TRUE' ? [r[0], r[1], r[2], 'FALSE', r[4]] : r
    end
    body = Google::Apis::SheetsV4::ValueRange.new(values: updates)
    @service.update_spreadsheet_value(
      @sheet_id, "보정!A2:E#{updates.size + 1}", body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] clear_corrections: #{e.message}"
  end

  def read_base_stats
    rows = read("스탯!A2:J30")
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
        skill2: r[8].to_s.strip,
        facing: r[9].to_s.strip.empty? ? '하' : r[9].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  def read_skill_data
    rows = read("스킬!A2:E50")
    rows.map do |r|
      {
        name:     r[0].to_s.strip,
        type:     r[1].to_s.strip,
        range:    r[2].to_s.strip,
        cooldown: r[3].to_s.strip,
        desc:     r[4].to_s.strip
      }
    end.reject { |r| r[:name].empty? }
  end

  def read_cooldowns
    rows = read("쿨타임!A2:C100")
    result = {}
    rows.each do |r|
      name  = r[0].to_s.strip
      skill = r[1].to_s.strip
      left  = r[2].to_i
      next if name.empty? || skill.empty?
      result[name] ||= {}
      result[name][skill] = left
    end
    result
  end

  def write_cooldowns(cooldowns_hash)
    rows = [['캐릭터명', '스킬명', '남은라운드수']]
    cooldowns_hash.each do |name, skills|
      skills.each do |skill, left|
        rows << [name, skill, left] if left > 0
      end
    end
    blank = Array.new(100) { ['', '', ''] }
    body_clear = Google::Apis::SheetsV4::ValueRange.new(values: blank)
    @service.update_spreadsheet_value(@sheet_id, "쿨타임!A2:C101", body_clear, value_input_option: 'RAW')
    return if rows.size <= 1
    body = Google::Apis::SheetsV4::ValueRange.new(values: rows[1..])
    @service.update_spreadsheet_value(
      @sheet_id, "쿨타임!A2:C#{rows.size}", body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] write_cooldowns: #{e.message}"
  end

  def read_commands(team_name)
    tab  = "#{team_name}커맨드"
    rows = read("#{tab}!A2:I50")
    rows.map do |r|
      next if r[0].to_s.strip.empty?
      {
        name:       r[0].to_s.strip,
        move_to:    r[1].to_s.strip,
        action:     r[2].to_s.strip,
        targets:    [r[3], r[4], r[5], r[6], r[7]].map { |t| t.to_s.strip }.reject(&:empty?),
        target_pos: r[8].to_s.strip,
        extra:      ''
      }
    end.compact
  end

  def read_current_state(team_name)
    tab  = "#{team_name}현황"
    rows = read("#{tab}!A2:D50")
    rows.map do |r|
      next if r[0].to_s.strip.empty?
      {
        name:   r[0].to_s.strip,
        pos:    r[1].to_s.strip,
        hp:     r[2].to_i,
        max_hp: r[3].to_i
      }
    end.compact
  end

  def read_current_state_a
    read_current_state('A팀')
  end

  def read_current_state_b
    read_current_state('B팀')
  end

  def update_current_state(states, team_name)
    tab  = "#{team_name}현황"
    rows = states.map { |s| [s[:name], s[:pos], s[:hp], s[:max_hp]] }
    body = Google::Apis::SheetsV4::ValueRange.new(values: rows)
    @service.update_spreadsheet_value(
      @sheet_id, "#{tab}!A2:D#{rows.size + 1}", body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] update_current_state: #{e.message}"
  end

  def update_map(all_states)
    grid = Array.new(8) { Array.new(8, '') }
    all_states.each do |s|
      pos = s[:pos].to_s.strip
      next if pos.empty?
      col = pos[0].upcase.ord - 'A'.ord
      row = pos[1..].to_i - 1
      next if col < 0 || col > 7 || row < 0 || row > 7
      grid[row][col] = s[:name]
    end
    write("맵!C2:J9", grid)
  end
end
