require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  SCOPE = Google::Apis::SheetsV4::AUTH_SPREADSHEETS

  MAP_RANGE   = "맵현황!B3:H10"
  STATE_RANGE = "현황!E4:I11"

  # 스탯 탭 헤더 별칭 (1행에서 자동 탐색)
  STAT_HEADERS = {
    name:    ['이름', '캐릭터명', '캐릭터'],
    hp:      ['건강', '체력', 'HP'],
    dur:     ['내구도'],
    atk:     ['마법능력', '마법 능력', '공격력'],
    agi:     ['민첩'],
    tec:     ['기술'],
    luck:    ['행운'],
    skill1:  ['스킬1', '스킬 1'],
    skill2:  ['스킬2', '스킬 2'],
    facing:  ['방향', 'facing', 'FACING', 'Facing'],
    house:   ['기숙사'],
    passive: ['패시브선택', '패시브 선택', '패시브']
  }.freeze

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

  # ── 스탯 탭: 1행 헤더 이름으로 열 위치 자동 탐색 ──
  def stat_column_map
    return @stat_column_map if @stat_column_map

    header = read("스탯!A1:Z1")[0] || []
    map = {}

    STAT_HEADERS.each do |key, aliases|
      idx = header.find_index { |h| aliases.include?(h.to_s.strip) }
      map[key] = idx
    end

    if map[:name].nil?
      puts "[Sheet 경고] 스탯 탭에서 '이름' 헤더를 찾지 못했습니다. 기본 열 배치(B=이름)로 동작합니다."
      map = { name: 1, hp: 2, dur: 3, atk: 4, agi: 5, tec: 6, luck: 7,
              skill1: 8, skill2: 9, facing: 10, house: 11, passive: 12 }
    end

    missing = STAT_HEADERS.keys.select { |k| map[k].nil? }
    puts "[Sheet 안내] 스탯 탭에서 다음 헤더를 찾지 못했습니다(빈값 처리): #{missing.join(', ')}" if missing.any?

    @stat_column_map = map
  end

  def row_to_stat(row, col)
    get = ->(key) { col[key] ? row[col[key]] : nil }

    hp = get.call(:hp).to_i

    {
      name:    get.call(:name).to_s.strip,
      hp:      hp,
      max_hp:  hp,
      dur:     get.call(:dur).to_i,
      atk:     get.call(:atk).to_i,
      agi:     get.call(:agi).to_i,
      tec:     get.call(:tec).to_i,
      luck:    get.call(:luck).to_i,
      skill1:  get.call(:skill1).to_s.strip,
      skill2:  get.call(:skill2).to_s.strip,
      facing:  get.call(:facing).to_s.strip.empty? ? '하' : get.call(:facing).to_s.strip,
      house:   get.call(:house).to_s.strip,
      passive: get.call(:passive).to_s.strip
    }
  end

  def read_base_stats
    col  = stat_column_map
    rows = read("스탯!A2:Z30")

    rows.map { |r| row_to_stat(r, col) }.reject { |r| r[:name].empty? }
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
        col
