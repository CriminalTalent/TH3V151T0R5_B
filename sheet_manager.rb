# sheet_manager.rb

def read_creature_config
  rows = read("보스!B2:B30")
  rows.each do |r|
    name = r[0].to_s.strip
    next if name.empty?
    return { name: name }
  end
  nil
end

def read_creature_stats(creature_name)
  rows = read("스탯!B2:K30")
  rows.each do |r|
    next if r[0].to_s.strip != creature_name
    return {
      name:   creature_name,
      hp:     r[1].to_i,
      dur:    r[2].to_i,
      atk:    r[3].to_i,
      agi:    r[4].to_i,
      tec:    r[5].to_i,
      luck:   r[6].to_i,
      skill1: r[7].to_s.strip,
      skill2: r[8].to_s.strip,
      facing: r[9].to_s.strip.empty? ? '하' : r[9].to_s.strip
    }
  end
  nil
end

def read_runner_state
  grid = read("자동봇!B4:I11")
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

  rows = read("자동봇!O15:S25")
  rows.map do |r|
    next if r[0].to_s.strip.empty?
    name = r[0].to_s.strip
    {
      name:   name,
      pos:    positions[name] || '',
      hp:     r[2].to_i,
      max_hp: r[4].to_i
    }
  end.compact
end

def update_runner_state(states)
  grid = Array.new(8) { Array.new(8, '') }
  table_rows = []

  states.each do |s|
    pos = s[:pos].to_s.strip
    if pos.match?(/^[A-H][1-8]$/)
      col = pos[0].upcase.ord - 'A'.ord
      row = pos[1..].to_i - 1
      grid[row][col] = s[:name]
    end
    table_rows << [s[:name], s[:pos], health_bar(s[:hp], s[:max_hp]), '', s[:max_hp]]
  end

  write("자동봇!B4:I11", grid)
  body = Google::Apis::SheetsV4::ValueRange.new(values: table_rows)
  @service.update_spreadsheet_value(
    @sheet_id, "자동봇!O15:S#{table_rows.size + 14}", body, value_input_option: 'RAW'
  )
rescue => e
  puts "[Sheet 오류] update_runner_state: #{e.message}"
end

def update_creature_state(state)
  grid = read("자동봇!B4:I11")
  grid.each_with_index do |row, row_idx|
    row.each_with_index do |cell, col_idx|
      if cell.to_s.strip == state[:name]
        grid[row_idx][col_idx] = ''
      end
    end
  end

  if state[:pos].match?(/^[A-H][1-8]$/)
    col = state[:pos][0].upcase.ord - 'A'.ord
    row = state[:pos][1..].to_i - 1
    grid[row][col] = state[:name]
  end

  write("자동봇!B4:I11", grid)

  creature_row = [state[:name], state[:pos], health_bar(state[:hp], state[:max_hp]), '', state[:max_hp]]
  write("자동봇!O27:S27", [creature_row])
rescue => e
  puts "[Sheet 오류] update_creature_state: #{e.message}"
end

def update_view_map(all_states)
  grid = Array.new(8) { Array.new(8, '') }
  all_states.each do |s|
    pos = s[:pos].to_s.strip
    next if pos.empty?
    col = pos[0].upcase.ord - 'A'.ord
    row = pos[1..].to_i - 1
    next if col < 0 || col > 7 || row < 0 || row > 7
    grid[row][col] = s[:name]
  end
  write("자동봇!C5:J12", grid)
end

def update_view_team(states, team_name)
  range = "자동봇!O16:S23"
  rows = Array.new(8) { ['', '', '', '', ''] }
  states.first(8).each_with_index do |s, i|
    bar = health_bar(s[:hp], s[:max_hp])
    rows[i] = [s[:name], s[:pos], bar, '', s[:max_hp]]
  end
  write(range, rows)
end

def update_view_creature(state)
  bar = health_bar(state[:hp], state[:max_hp])
  write("자동봇!O28:S28", [[state[:name], state[:pos], bar, '', state[:max_hp]]])
end
