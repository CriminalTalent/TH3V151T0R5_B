# battle_grid.rb
# encoding: UTF-8

module BattleGrid
  COLS = ('A'..'G').to_a.freeze
  ROWS = (1..8).to_a.freeze

  module_function

  def parse_pos(pos)
    text = pos.to_s.strip.upcase
    return nil unless text.match?(/\A[A-G][1-8]\z/)
    [COLS.index(text[0]), text[1].to_i - 1]
  end

  def format_pos(x, y)
    return nil unless x && y
    return nil unless x.between?(0, COLS.size - 1) && y.between?(0, ROWS.size - 1)
    "#{COLS[x]}#{y + 1}"
  end

  def valid_pos?(pos)
    !parse_pos(pos).nil?
  end

  def distance(a, b)
    ax, ay = parse_pos(a)
    bx, by = parse_pos(b)
    return nil unless ax && bx
    [(ax - bx).abs, (ay - by).abs].max
  end

  def manhattan(a, b)
    ax, ay = parse_pos(a)
    bx, by = parse_pos(b)
    return nil unless ax && bx
    (ax - bx).abs + (ay - by).abs
  end

  def adjacent?(a, b)
    d = distance(a, b)
    d && d == 1
  end

  def parse_size(size)
    text = size.to_s.strip.downcase
    match = text.match(/(\d+)\s*x\s*(\d+)/)
    return [1, 1] unless match
    w = match[1].to_i
    h = match[2].to_i
    w = 1 if w <= 0
    h = 1 if h <= 0
    [w, h]
  end

  def parse_cell_list(text)
    text.to_s.upcase.scan(/[A-Z][0-9]+/).select { |cell| valid_pos?(cell) }.uniq
  end

  def creature_cells(creature)
    explicit = creature[:cells] || creature[:occupied_cells] || creature[:점유칸]
    explicit_cells = parse_cell_list(explicit)
    return explicit_cells unless explicit_cells.empty?

    base = creature[:pos].to_s.strip.upcase
    width, height = parse_size(creature[:size] || creature[:크기] || creature[:body_size])
    x, y = parse_pos(base)
    return [] unless x && y

    cells = []
    height.times do |dy|
      width.times do |dx|
        cell = format_pos(x + dx, y + dy)
        cells << cell if cell
      end
    end
    cells
  end

  def occupied_by_runners(runner_state, except_name: nil)
    runner_state.to_a.each_with_object({}) do |runner, map|
      next if except_name && runner[:name].to_s == except_name.to_s
      pos = runner[:pos].to_s.strip.upcase
      next unless valid_pos?(pos)
      map[pos] = runner[:name].to_s
    end
  end

  def occupied_by_creature(creature)
    creature_cells(creature).each_with_object({}) do |cell, map|
      map[cell] = creature[:name].to_s
    end
  end

  def occupied?(coord, runner_state, creature, except_name: nil)
    pos = coord.to_s.strip.upcase
    occupied_by_runners(runner_state, except_name: except_name).key?(pos) ||
      occupied_by_creature(creature).key?(pos)
  end

  def movable?(from, to, runner_state, creature, actor_name: nil)
    from = from.to_s.strip.upcase
    to = to.to_s.strip.upcase

    return [false, '이동 좌표가 올바르지 않습니다. A1~G8 범위로 입력해주세요.'] unless valid_pos?(to)
    return [false, '이동은 가로/세로/대각선으로 1칸만 가능합니다.'] unless adjacent?(from, to)

    runner_block = occupied_by_runners(runner_state, except_name: actor_name)[to]
    return [false, "이미 #{runner_block}이(가) 있는 칸입니다."] if runner_block

    if occupied_by_creature(creature).key?(to)
      return [false, "#{creature[:name]}이(가) 점유한 칸으로는 이동할 수 없습니다."]
    end

    [true, nil]
  end

  def distance_to_creature(pos, creature)
    cells = creature_cells(creature)
    return nil if cells.empty?
    cells.map { |cell| distance(pos, cell) }.compact.min
  end

  def in_range?(from, target, range, creature: nil)
    range_text = range.to_s.strip
    return true if range_text.empty? || range_text == '-' || range_text == '전체' || range_text == '특정마스'
    return true if range_text == '자신' && from.to_s.strip.upcase == target.to_s.strip.upcase

    limit = range_text == '근접' ? 1 : range_text.to_i
    limit = 1 if limit <= 0

    if creature && ['크리쳐', creature[:name].to_s].include?(target.to_s.strip)
      d = distance_to_creature(from, creature)
    else
      d = distance(from, target)
    end

    d && d <= limit
  end

  def line_clear?(from, to, runner_state, creature, actor_name: nil)
    ax, ay = parse_pos(from)
    bx, by = parse_pos(to)
    return false unless ax && bx

    dx = bx <=> ax
    dy = by <=> ay
    return false unless ax == bx || ay == by || (bx - ax).abs == (by - ay).abs

    x = ax + dx
    y = ay + dy
    while x != bx || y != by
      cell = format_pos(x, y)
      return false if occupied_by_runners(runner_state, except_name: actor_name).key?(cell)
      return false if occupied_by_creature(creature).key?(cell)
      x += dx
      y += dy
    end

    true
  end

  # ──────────────────────────────────────────────
  # 전장 표시용 약칭
  # ──────────────────────────────────────────────

  def display_name_for_runner(name, runner_state = [])
    runner = runner_state.to_a.find { |r| r[:name].to_s == name.to_s }
    display = runner && (runner[:display_name] || runner[:label] || runner[:name])
    display.to_s.strip.empty? ? name.to_s : display.to_s.strip
  end

  def first_chars(text, length)
    chars = text.to_s.strip.each_char.to_a
    value = chars.first(length).join
    value.empty? ? '?' : value
  end

  def unique_symbol_map(names)
    labels = names.map { |n| [n, n.to_s.strip] }.to_h
    result = {}
    used = {}

    names.each do |name|
      label = labels[name]
      symbol = nil
      max_len = [label.each_char.count, 1].max
      (1..max_len).each do |len|
        candidate = first_chars(label, len)
        unless used[candidate]
          symbol = candidate
          break
        end
      end
      unless symbol
        base = first_chars(label, 1)
        i = 2
        i += 1 while used["#{base}#{i}"]
        symbol = "#{base}#{i}"
      end
      used[symbol] = true
      result[name] = symbol
    end

    result
  end

  def symbol_maps(runner_state, creature)
    runner_names = runner_state.to_a.map { |r| r[:name].to_s }.reject(&:empty?).uniq
    runner_labels = runner_names.map { |n| display_name_for_runner(n, runner_state) }
    creature_name = creature[:name].to_s.strip.empty? ? '보스' : creature[:name].to_s.strip

    all_display_names = runner_labels + [creature_name]
    all_symbols = unique_symbol_map(all_display_names)

    runner_symbol_by_name = {}
    runner_names.each_with_index do |name, idx|
      display = runner_labels[idx]
      runner_symbol_by_name[name] = all_symbols[display]
    end

    creature_symbol = all_symbols[creature_name]
    [runner_symbol_by_name, creature_symbol, creature_name]
  end

  def render(runner_state, creature, pattern_cells: [], danger_cells: [], heal_cells: [])
    runner_by_pos = occupied_by_runners(runner_state)
    creature_by_pos = occupied_by_creature(creature)
    pattern_cells = parse_cell_list(pattern_cells.join(' ')) if pattern_cells.is_a?(Array)
    danger_cells = parse_cell_list(danger_cells.join(' ')) if danger_cells.is_a?(Array)
    heal_cells = parse_cell_list(heal_cells.join(' ')) if heal_cells.is_a?(Array)

    runner_symbols, creature_symbol, creature_name = symbol_maps(runner_state, creature)

    lines = []
    lines << '      A   B   C   D   E   F   G'
    ROWS.each do |row|
      y = row - 1
      cells = COLS.each_with_index.map do |_col, x|
        pos = format_pos(x, y)
        mark = if runner_by_pos[pos]
                 runner_symbols[runner_by_pos[pos]] || '러'
               elsif creature_by_pos[pos]
                 creature_symbol || '보'
               elsif danger_cells.include?(pos)
                 '※'
               elsif pattern_cells.include?(pos)
                 '범'
               elsif heal_cells.include?(pos)
                 '♥'
               else
                 '□'
               end
        mark.to_s.ljust(2)
      end
      lines << format('%2d   %s', row, cells.join(' '))
    end

    lines << ''
    lines << '[약칭]'
    runner_state.to_a.each do |runner|
      name = runner[:name].to_s
      display = display_name_for_runner(name, runner_state)
      symbol = runner_symbols[name] || '러'
      lines << "#{symbol} = #{display}"
    end
    lines << "#{creature_symbol} = #{creature_name}"
    lines << '범 = 예고 범위 / ※ = 위험 범위 / ♥ = 회복 구역 / □ = 빈칸'
    lines
  end
end
