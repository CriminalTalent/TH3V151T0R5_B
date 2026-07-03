require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  SCOPE = Google::Apis::SheetsV4::AUTH_SPREADSHEETS

  MAP_RANGE   = "맵현황!B3:H10"
  STATE_RANGE = "현황!E4:I11"

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

  # 스탯 탭: B=이름 C=건강 D=내구도 E=마법능력 F=민첩 G=기술 H=행운
  #          I=스킬1 J=스킬2 K=방향 L=기숙사 M=패시브선택(1/2)
  def read_base_stats
    rows = read("스탯!B2:M30")

    rows.map do |r|
      {
        name:    r[0].to_s.strip,
        hp:      r[1].to_i,
        max_hp:  r[1].to_i,
        dur:     r[2].to_i,
        atk:     r[3].to_i,
        agi:     r[4].to_i,
        tec:     r[5].to_i,
        luck:    r[6].to_i,
        skill1:  r[7].to_s.strip,
        skill2:  r[8].to_s.strip,
        facing:  r[9].to_s.strip.empty? ? '하' : r[9].to_s.strip,
        house:   r[10].to_s.strip,
        passive: r[11].to_s.strip
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
    write("쿨타임!A2:C101", Array.new(100) { ['', '', ''] })

    rows = []

    cooldowns_hash.each do |name, skills|
      skills.each do |skill, left|
        rows << [name, skill, left] if left.to_i > 0
      end
    end

    return if rows.empty?

    write("쿨타임!A2:C#{rows.size + 1}", rows)
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
    write("버프!A2:D201", Array.new(200) { ['', '', '', ''] })

    rows = []

    buffs_hash.each do |name, list|
      list.each do |b|
        left = b[:left].to_i
        rows << [name, b[:type], b[:value], left] if left > 0 || left == 999
      end
    end

    return if rows.empty?

    write("버프!A2:D#{rows.size + 1}", rows)
  rescue => e
    puts "[Sheet 오류] write_buffs: #{e.message}"
  end

  def read_runner_state
    grid = normalize_grid(read(MAP_RANGE), 8, 7)
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

    rows = normalize_grid(read(STATE_RANGE), 8, 5)

    rows.map do |r|
      name = r[0].to_s.strip
      next if name.empty?

      {
        name:   name,
        pos:    r[1].to_s.strip.empty? ? positions[name].to_s : r[1].to_s.strip,
        hp:     extract_hp_current(r[2]),
        max_hp: r[3].to_i,
        status: r[4].to_s.strip
      }
    end.compact
  end

  def update_runner_state(states)
    grid = Array.new(8) { Array.new(7, '') }
    table_rows = Array.new(8) { ['', '', '', '', ''] }

    states.first(8).each_with_index do |s, i|
      name   = s[:name].to_s.strip
      pos    = s[:pos].to_s.strip.upcase
      hp     = s[:hp].to_i
      max_hp = s[:max_hp].to_i
      status = s[:status].to_s.strip

      if pos.match?(/^[A-G][1-8]$/)
        col = pos[0].ord - 'A'.ord
        row = pos[1..].to_i - 1
        grid[row][col] = name
      end

      table_rows[i] = [
        name,
        pos,
        health_bar(hp, max_hp),
        max_hp,
        status
      ]
    end

    write(MAP_RANGE, grid)
    write(STATE_RANGE, table_rows)
  rescue => e
    puts "[Sheet 오류] update_runner_state: #{e.message}"
  end

  def read_creature_config
    rows = read("보스!A1:K50")

    rows.each do |r|
      active_idx = r.find_index { |v| v.to_s.strip.upcase == "TRUE" }
      next if active_idx.nil?

      candidates = []

      ((active_idx + 1)...r.size).each do |i|
        candidates << r[i].to_s.strip
      end

      (0...active_idx).reverse_each do |i|
        candidates << r[i].to_s.strip
      end

      name = candidates.find do |v|
        !v.empty? &&
          v.upcase != "TRUE" &&
          v.upcase != "FALSE" &&
          !["이름", "활성화", "버튼", "보스"].include?(v)
      end

      return { name: name } if name
    end

    { name: "크리쳐" }
  end

  def read_creature_stats(creature_name)
    rows = read("스탯!B2:M30")
    target = creature_name.to_s.strip

    rows.each do |r|
      name = r[0].to_s.strip
      next if name != target

      hp = r[1].to_i

      return {
        name:   name,
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
        pos:    'D4',
        status: ''
      }
    end

    {
      name: target.empty? ? "크리쳐" : target,
      hp: 200,
      max_hp: 200,
      pos: "D4",
      facing: "하",
      status: ''
    }
  end

  def update_creature_state(state)
    grid = normalize_grid(read(MAP_RANGE), 8, 7)

    name = state[:name].to_s.strip
    pos  = state[:pos].to_s.strip.upcase

    grid.each_with_index do |row, row_idx|
      row.each_with_index do |cell, col_idx|
        grid[row_idx][col_idx] = '' if cell.to_s.strip == name
      end
    end

    if pos.match?(/^[A-G][1-8]$/)
      col = pos[0].ord - 'A'.ord
      row = pos[1..].to_i - 1
      grid[row][col] = name
    end

    write(MAP_RANGE, grid)
  rescue => e
    puts "[Sheet 오류] update_creature_state: #{e.message}"
  end

  def update_view_map(all_states)
    grid = Array.new(8) { Array.new(7, '') }

    all_states.each do |s|
      name = s[:name].to_s.strip
      pos  = s[:pos].to_s.strip.upcase
      next if name.empty?
      next unless pos.match?(/^[A-G][1-8]$/)

      col = pos[0].ord - 'A'.ord
      row = pos[1..].to_i - 1
      grid[row][col] = name
    end

    write(MAP_RANGE, grid)
  end

  def update_view_team(states, team_name = nil)
    update_runner_state(states)
  end

  def update_view_creature(state)
    update_creature_state(state)
  end

  def clear_round_status
    states = read_runner_state
    states.each { |s| s[:status] = '' }
    update_runner_state(states)
  end

  def health_bar(current, max)
    current = current.to_i
    max = max.to_i

    return "0/0" if max <= 0

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
end
