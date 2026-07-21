require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  SCOPE = Google::Apis::SheetsV4::AUTH_SPREADSHEETS

  MAP_RANGE   = "맵현황!B3:H10"
  STATE_RANGE = "현황!E4:H11"

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

  def read_base_stats
    rows = read("스탯!B2:K30")
    rows.map do |r|
      {
        name:     r[0].to_s.strip,
        house:    '',
        passive:  '1',
        hp:       r[1].to_i,
        dur:      r[2].to_i,
        atk:      r[3].to_i,
        agi:      r[4].to_i,
        tec:      r[5].to_i,
        luck:     r[6].to_i,
        skill1:   r[7].to_s.strip,
        skill2:   r[8].to_s.strip,
        facing:   r[9].to_s.strip.empty? ? '하' : r[9].to_s.strip
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

  def read_battle_state
    rows = read("전투상태!A2:C2")
    return nil if rows.empty?
    row = rows[0]
    {
      round: row[0].to_i,
      status: row[1].to_s.strip,
      timestamp: row[2].to_s.strip
    }
  rescue
    nil
  end

  def write_battle_state(round, status)
    write("전투상태!A2:C2", [[round, status, Time.now.to_s]])
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
    write("쿨타임!A2:C101", blank)
    return if rows.size <= 1

    write("쿨타임!A2:C#{rows.size}", rows[1..])
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
    write("버프!A2:D201", blank)
    return if rows.size <= 1

    write("버프!A2:D#{rows.size}", rows[1..])
  rescue => e
    puts "[Sheet 오류] write_buffs: #{e.message}"
  end

  def read_runner_state
    grid = read(MAP_RANGE)
    positions = {}

    grid.each_with_index do |row, row_idx|
      row.each_with_index do |cell, col_idx|
        name = cell.to_s.strip
        next if name.empty?

        col_letter = ('A'.ord + col_idx).chr
        row_number = row_idx + 1
        positions[name] = "#{col_letter}#{row_number}"
      end
    end

    rows = read(STATE_RANGE)
    rows.map do |r|
      next if r[0].to_s.strip.empty?

      name = r[0].to_s.strip
      {
        name:   name,
        pos:    r[1].to_s.strip.empty? ? positions[name].to_s : r[1].to_s.strip,
        hp:     extract_hp_current(r[2]),
        max_hp: r[3].to_i
      }
    end.compact
  end

  def update_runner_state(states)
    grid = Array.new(8) { Array.new(7, '') }
    table_rows = Array.new(8) { ['', '', '', ''] }

    states.first(8).each_with_index do |s, i|
      pos = s[:pos].to_s.strip.upcase

      if pos.match?(/^[A-G][1-8]$/)
        col = pos[0].ord - 'A'.ord
        row = pos[1..].to_i - 1
        grid[row][col] = s[:name]
      end

      table_rows[i] = [
        s[:name],
        pos,
        health_bar(s[:hp], s[:max_hp]),
        s[:max_hp]
      ]
    end

    write(MAP_RANGE, grid)
    write(STATE_RANGE, table_rows)
  rescue => e
    puts "[Sheet 오류] update_runner_state: #{e.message}"
  end

  def read_creature_config
    rows = read("보스!B2:B30")
    rows.each do |r|
      name = r[0].to_s.strip
      next if name.empty?
      return { name: name }
    end
    { name: "크리쳐" }
  end

  def read_creature_stats(creature_name)
    rows = read("스탯!B2:K30")
    rows.each do |r|
      next if r[0].to_s.strip != creature_name

      hp = r[1].to_i
      return {
        name:   creature_name,
        hp:     hp,
        max_hp: hp,
        dur:    r[2].to_i,
        atk:    r[3].to_i,
        agi:    r[4].to_i,
        tec:    r[5].to_i,
        luck:   r[6].to_i,
        skill1: r[7].to_s.strip,
        skill2: r[8].to_s.strip,
        facing: r[9].to_s.strip.empty? ? '하' : r[9].to_s.strip,
        pos:    'D4'
      }
    end

    {
      name: "크리쳐",
      hp: 200,
      max_hp: 200,
      pos: "D4",
      facing: "하"
    }
  end

  def update_creature_state(state)
    grid = read(MAP_RANGE)
    grid = normalize_grid(grid, 8, 7)

    grid.each_with_index do |row, row_idx|
      row.each_with_index do |cell, col_idx|
        grid[row_idx][col_idx] = '' if cell.to_s.strip == state[:name].to_s.strip
      end
    end

    pos = state[:pos].to_s.strip.upcase
    if pos.match?(/^[A-G][1-8]$/)
      col = pos[0].ord - 'A'.ord
      row = pos[1..].to_i - 1
      grid[row][col] = state[:name]
    end

    write(MAP_RANGE, grid)
  rescue => e
    puts "[Sheet 오류] update_creature_state: #{e.message}"
  end

  def health_bar(current, max)
    return "0/0" if max.to_i <= 0

    ratio  = current.to_f / max.to_f
    filled = (ratio * 10).round
    filled = [[filled, 10].min, 0].max
    bar = ("█" * filled) + ("░" * (10 - filled))

    "#{bar}  #{current}/#{max}"
  end

  def extract_hp_current(value)
    text = value.to_s
    match = text.match(/(\d+)\s*\/\s*(\d+)/)
    return match[1].to_i if match

    text.to_i
  end

  def normalize_grid(grid, rows, cols)
    Array.new(rows) do |r|
      Array.new(cols) do |c|
        grid.dig(r, c).to_s
      end
    end
  end

  def update_view_map(all_states)
    grid = Array.new(8) { Array.new(7, '') }

    all_states.each do |s|
      pos = s[:pos].to_s.strip.upcase
      next unless pos.match?(/^[A-G][1-8]$/)

      col = pos[0].ord - 'A'.ord
      row = pos[1..].to_i - 1
      grid[row][col] = s[:name]
    end

    write(MAP_RANGE, grid)
  end

  def update_view_team(states, team_name = nil)
    update_runner_state(states)
  end

  def update_view_creature(state)
    update_creature_state(state)
  end
end
