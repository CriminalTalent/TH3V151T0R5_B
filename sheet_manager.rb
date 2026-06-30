# sheet_manager.rb
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

  # ─── 운영 시트 (OPS) ─────────────────────────────────────────────

  def read_trigger
    rows = read("실행!A2:D2")
    return nil if rows.empty?
    row = rows[0]
    {
      on:    row[0].to_s.upcase == 'TRUE',
      round: row[1].to_i,
      team:  'A팀'
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
    rows = read("스탯!A2:M30")
    rows.map do |r|
      {
        name:     r[1].to_s.strip,
        house:    r[2].to_s.strip,
        passive:  r[3].to_s.strip.empty? ? '1' : r[3].to_s.strip,
        hp:       r[4].to_i,
        dur:      r[5].to_i,
        atk:      r[6].to_i,
        agi:      r[7].to_i,
        tec:      r[8].to_i,
        luck:     r[9].to_i,
        skill1:   r[10].to_s.strip,
        skill2:   r[11].to_s.strip,
        facing:   r[12].to_s.strip.empty? ? '하' : r[12].to_s.strip
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

  def read_buffs
    rows = read("버프!A2:D200")
    result = {}
    rows.each do |r|
      name = r[0].to_s.strip
      type = r[1].to_s.strip
      val  = r[2].to_s.strip
      left = r[3].to_i
      next if name.empty? || type.empty?
      result[name] ||= []
      result[name] << { type: type, value: val, left: left }
    end
    result
  end

  def write_buffs(buffs_hash)
    rows = [['캐릭터명', '종류', '값', '남은라운드수']]
    buffs_hash.each do |name, list|
      list.each do |b|
        rows << [name, b[:type], b[:value], b[:left]] if b[:left] > 0 || b[:left] == 999
      end
    end
    blank = Array.new(200) { ['', '', '', ''] }
    body_clear = Google::Apis::SheetsV4::ValueRange.new(values: blank)
    @service.update_spreadsheet_value(@sheet_id, "버프!A2:D201", body_clear, value_input_option: 'RAW')
    return if rows.size <= 1
    body = Google::Apis::SheetsV4::ValueRange.new(values: rows[1..])
    @service.update_spreadsheet_value(
      @sheet_id, "버프!A2:D#{rows.size}", body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] write_buffs: #{e.message}"
  end

  # ─── 러너 시트 (RUNNER_SHEET_ID) ──────────────────────────────────

  def read_runner_commands
    rows = read("커맨드!A2:I50")
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

  def read_runner_state
    rows = read("현황!A2:D50")
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

  def update_runner_state(states)
    rows = states.map { |s| [s[:name], s[:pos], s[:hp], s[:max_hp]] }
    body = Google::Apis::SheetsV4::ValueRange.new(values: rows)
    @service.update_spreadsheet_value(
      @sheet_id, "현황!A2:D#{rows.size + 1}", body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] update_runner_state: #{e.message}"
  end

  # ─── 크리쳐 시트 (CREATURE_SHEET_ID) ───────────────────────────────

  def read_creature_config
    rows = read("보스!A2:E30")
    rows.each do |r|
      next if r[4].to_s.upcase != 'TRUE'
      return {
        name:  r[1].to_s.strip,
        credit: r[2].to_i,
        item:  r[3].to_s.strip
      }
    end
    nil
  end

  def read_creature_stats(creature_name)
    rows = read("스탯!A2:M30")
    rows.each do |r|
      next if r[1].to_s.strip != creature_name
      return {
        name:   creature_name,
        hp:     r[4].to_i,
        dur:    r[5].to_i,
        atk:    r[6].to_i,
        agi:    r[7].to_i,
        tec:    r[8].to_i,
        luck:   r[9].to_i,
        skill1: r[10].to_s.strip,
        skill2: r[11].to_s.strip,
        facing: r[12].to_s.strip.empty? ? '하' : r[12].to_s.strip
      }
    end
    nil
  end

  def update_creature_state(state)
    rows = read("현황!A2:D50")
    rows[0] = [state[:name], state[:pos], state[:hp], state[:max_hp]]
    body = Google::Apis::SheetsV4::ValueRange.new(values: rows)
    @service.update_spreadsheet_value(
      @sheet_id, "현황!A2:D#{rows.size + 1}", body, value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] update_creature_state: #{e.message}"
  end
end
