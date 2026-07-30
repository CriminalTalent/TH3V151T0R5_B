# scout_directions.rb
# encoding: UTF-8
#
# 전투 종료(승리/패배/도망 성공/말걸기 성공) 후, 러너의 조사맵 격자 위치를
# 바탕으로 이동 가능한 방향을 계산해 안내한다.
# 조사봇(TH3V151T0R5_F)의 격자 좌표계(C~O, 2~8)와 동일한 규칙을 그대로 사용하며,
# 조사봇의 "조사상태"/"장소" 시트를 읽기 전용으로 조회하기만 한다
# (조사봇 코드/시트 구조는 건드리지 않는다).

module ScoutDirections
  COLS = ('C'..'O').to_a.freeze
  ROWS = (2..8).to_a.freeze
  COORD_RE = /\A([C-O])([2-8])\z/.freeze

  DIRECTIONS = {
    '북쪽' => [0, -1],
    '남쪽' => [0, 1],
    '동쪽' => [1, 0],
    '서쪽' => [-1, 0]
  }.freeze

  TRUTHY = %w[TRUE 1 ON YES Y ✓ ✔].freeze

  module_function

  def valid_coord?(coord)
    !!coord.to_s.strip.upcase.match(COORD_RE)
  end

  def neighbor_coord(coord, delta)
    m = coord.to_s.strip.upcase.match(COORD_RE)
    return nil unless m

    col_idx = COLS.index(m[1])
    row_idx = ROWS.index(m[2].to_i)
    return nil unless col_idx && row_idx

    nc = col_idx + delta[0]
    nr = row_idx + delta[1]
    return nil unless nc.between?(0, COLS.length - 1)
    return nil unless nr.between?(0, ROWS.length - 1)

    "#{COLS[nc]}#{ROWS[nr]}"
  end

  def header_index(header_row)
    map = {}
    header_row.to_a.each_with_index { |h, i| map[h.to_s.strip] = i }
    map
  end

  # 조사봇 "조사상태" 시트에서 계정의 현재 좌표를 읽는다.
  def find_location(scout_sheet, acct)
    return nil unless scout_sheet

    acct = acct.to_s.gsub('@', '').strip
    rows = scout_sheet.read("'조사상태'!A:C")
    return nil if rows.empty?

    idx = header_index(rows[0])
    id_col  = idx['ID'] || 0
    loc_col = idx['위치'] || 1

    rows[1..].to_a.each do |row|
      id = row[id_col].to_s.gsub('@', '').strip
      next unless id == acct

      return row[loc_col].to_s.strip.upcase
    end

    nil
  rescue => e
    puts "[ScoutDirections.find_location 오류] #{e.class}: #{e.message}"
    nil
  end

  # "장소" 시트에서 좌표의 공개여부/막힌방향을 읽는다.
  def find_cell(sheet, coord)
    return nil unless sheet

    rows = sheet.read("'장소'!A:S")
    return nil if rows.empty?

    idx = header_index(rows[0])
    pos_col     = idx['위치'] || 0
    public_col  = idx['공개여부']
    blocked_col = idx['막힌방향']

    rows[1..].to_a.each do |row|
      code = row[pos_col].to_s.strip.upcase
      next unless code == coord

      public_val  = public_col ? row[public_col].to_s.strip.upcase : ''
      blocked_val = blocked_col ? row[blocked_col].to_s.strip : ''

      return {
        public:  TRUTHY.include?(public_val),
        blocked: blocked_val
      }
    end

    nil
  rescue => e
    puts "[ScoutDirections.find_cell 오류] #{e.class}: #{e.message}"
    nil
  end

  # 조사봇의 메인 시트(scout_sheet) → 조사맵 시트(grid_sheet) 순으로 찾는다
  # (조사봇 sheet_manager.rb의 find_location 우선순위와 동일).
  def find_cell_any(scout_sheet, grid_sheet, coord)
    find_cell(scout_sheet, coord) || find_cell(grid_sheet, coord)
  end

  def blocked_list(cell)
    return [] unless cell

    cell[:blocked].to_s.split(/[,\s\/]+/).map(&:strip).reject(&:empty?)
  end

  def available_directions(scout_sheet, grid_sheet, coord)
    current_cell = find_cell_any(scout_sheet, grid_sheet, coord)
    blocked = blocked_list(current_cell)

    DIRECTIONS.each_with_object([]) do |(name, delta), list|
      next if blocked.include?(name)

      target = neighbor_coord(coord, delta)
      next unless target

      target_cell = find_cell_any(scout_sheet, grid_sheet, target)
      list << name if target_cell && target_cell[:public]
    end
  end

  # 계정 한 명에 대한 안내 문자열. 격자 좌표가 아니거나 이동 가능한 방향이
  # 없으면 nil을 반환한다.
  def build_announcement(scout_sheet, grid_sheet, acct)
    coord = find_location(scout_sheet, acct)
    return nil unless valid_coord?(coord)

    directions = available_directions(scout_sheet, grid_sheet, coord)
    return nil if directions.empty?

    lines = ['이동 가능한 방향:']
    directions.each { |name| lines << "[탐사/#{name}]" }
    lines.join("\n")
  end

  # ── 크리쳐 처치 보상 크레딧 지급 ──
  #
  # 조사봇의 "사용자" 시트(ID/이름/크레딧/아이템/기숙사)에 직접 크레딧을 더한다.
  # 계정을 찾지 못하면 nil을 반환한다.

  def column_letter(index)
    result = ''
    n = index + 1

    while n > 0
      n -= 1
      result.prepend((65 + (n % 26)).chr)
      n /= 26
    end

    result
  end

  def add_credits(scout_sheet, acct, amount)
    return nil unless scout_sheet
    return nil if amount.to_i == 0

    acct = acct.to_s.gsub('@', '').strip
    rows = scout_sheet.read("'사용자'!A:E")
    return nil if rows.empty?

    idx = header_index(rows[0])
    id_col     = idx['ID'] || 0
    credit_col = idx['크레딧'] || 2

    rows[1..].to_a.each_with_index do |row, i|
      id = row[id_col].to_s.gsub('@', '').strip
      next unless id == acct

      current = row[credit_col].to_s.strip.to_i
      new_credits = [current + amount.to_i, 0].max

      scout_sheet.write("'사용자'!#{column_letter(credit_col)}#{i + 2}", [[new_credits]])
      return new_credits
    end

    nil
  rescue => e
    puts "[ScoutDirections.add_credits 오류] #{e.class}: #{e.message}"
    nil
  end
end
