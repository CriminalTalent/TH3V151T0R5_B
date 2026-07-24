# sheet_manager.rb
# encoding: UTF-8

require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  def initialize(sheet_id, credentials_path)
    @sheet_id = sheet_id

    @service = Google::Apis::SheetsV4::SheetsService.new
    @service.client_options.application_name = 'TH3V151T0R5 BattleBot'
    @service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: File.open(credentials_path),
      scope: ['https://www.googleapis.com/auth/spreadsheets']
    )
  end

  # ──────────────────────────────────────────────
  # 전투로그 탭 기록 (실패해도 봇 동작에는 영향 없음)
  # ──────────────────────────────────────────────

  BATTLE_LOG_SHEET = '전투로그'.freeze

  def append_battle_log(row)
    body = Google::Apis::SheetsV4::ValueRange.new(values: [row])
    @service.append_spreadsheet_value(
      @sheet_id, "#{BATTLE_LOG_SHEET}!A:E", body,
      value_input_option: 'RAW'
    )
    true
  rescue => e
    puts "[전투로그 기록 실패] #{e.class}: #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 기본 I/O
  # ──────────────────────────────────────────────

  def read(range)
    @service.get_spreadsheet_values(@sheet_id, range).values || []
  rescue => e
    puts "[시트 읽기 오류] #{range}: #{e.message}"
    []
  end

  def write(range, values)
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @service.update_spreadsheet_value(
      @sheet_id,
      range,
      body,
      value_input_option: 'USER_ENTERED'
    )
    true
  rescue => e
    puts "[시트 쓰기 오류] #{range}: #{e.message}"
    false
  end

  def append(range, values)
    body = Google::Apis::SheetsV4::ValueRange.new(values: [values])
    @service.append_spreadsheet_value(
      @sheet_id,
      range,
      body,
      value_input_option: 'USER_ENTERED'
    )
    true
  rescue => e
    puts "[시트 추가 오류] #{range}: #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 실행 탭
  # A2 = 전투봇 켜기/끄기 체크박스
  # B2 = 퍼블릭/DM 체크박스
  # ──────────────────────────────────────────────

  def read_bot_on
    rows = read("'실행'!A2")
    return false if rows.empty? || rows[0].nil?
    truthy?(rows[0][0])
  end

  # 시트 읽기 실패(타임아웃 등) 시 nil을 반환해 호출부가 이전 상태를 유지할 수 있게 합니다.
  def read_bot_on_or_nil
    rows = @service.get_spreadsheet_values(@sheet_id, "'실행'!A2").values || []
    return false if rows.empty? || rows[0].nil?
    truthy?(rows[0][0])
  rescue => e
    puts "[시트 읽기 오류] '실행'!A2: #{e.message} (이전 상태 유지)"
    nil
  end

  def read_visibility
    rows = read("'실행'!B2")
    return 'direct' if rows.empty? || rows[0].nil? || rows[0][0].to_s.strip.empty?
    truthy?(rows[0][0]) ? 'public' : 'direct'
  end


  def read_auto_mode
    rows = read("'실행'!C2")
    return false if rows.empty? || rows[0].nil?
    truthy?(rows[0][0])
  end

  def update_position(runner_name, pos)
    return false unless pos.to_s.match?(/\A[A-G][1-8]\z/)
    begin
      rows = read_range('D3', 'A:Z')
      return false if rows.empty?
      headers = header_map(rows[0])
      pos_col = header_col(headers, '위치', 'B')
      row_idx = rows.find_index { |row| row[1].to_s.strip == runner_name.to_s.strip }
      return false unless row_idx
      write_range('D3', "#{pos_col}#{row_idx + 1}", [[pos]])
      true
    rescue => e
      puts "[update_position 오류] #{e.class}: #{e.message}"
      false
    end
  end

  # ──────────────────────────────────────────────
  # 크리쳐 활성화 정보
  # ──────────────────────────────────────────────

  def read_creature_config
    # 보스 탭은 사용하지 않습니다. 크리쳐는 스탯 탭의 활성 행으로만 결정합니다.
    nil
  end

  # ──────────────────────────────────────────────
  # 러너 스탯
  #
  # 자동봇 시트 / 스탯 탭 구조:
  # A ID
  # B 이름
  # C 기숙사
  # D 패시브선택
  # E 건강
  # F 내구도
  # G 마법능력
  # H 민첩
  # I 기술
  # J 행운
  # K 스킬1
  # L 스킬2
  # M facing
  #
  # E열 건강은 전투 중 현재 체력으로 갱신합니다.
  # 최대체력은 전투 세션 시작 시 읽은 건강값을 battle_round.rb의 ctx에 보존합니다.
  # ──────────────────────────────────────────────

  def read_base_stats
    rows = read("'스탯'!A2:M100")

    rows.map do |row|
      id = row[0].to_s.strip
      next if id.empty?

      # E열이 비어있거나 숫자가 아니면 기본 50, "0"이면 전투불가(0) 그대로 유지
      hp_raw = row[4].to_s.strip
      hp = hp_raw.match?(/\A-?\d+\z/) ? [hp_raw.to_i, 0].max : 50

      # K열(최대건강)이 비어있거나 숫자가 아니면 현재 건강을 최대건강으로 사용
      max_hp_raw = row[10].to_s.strip
      max_hp = max_hp_raw.match?(/\A-?\d+\z/) && max_hp_raw.to_i > 0 ? max_hp_raw.to_i : hp

      {
        name:         id,
        id:           id,
        display_name: row[1].to_s.strip,
        house:        row[2].to_s.strip,
        passive:      row[3].to_s.strip,
        hp:           hp,
        max_hp:       max_hp,
        dur:          row[5].to_i,
        atk:          row[6].to_i,
        agi:          row[7].to_i,
        tec:          row[8].to_i,
        luck:         row[9].to_i,
        skill1:       '',
        skill2:       row[11].to_s.strip,
        facing:       row[12].to_s.strip.empty? ? '하' : row[12].to_s.strip
      }
    end.compact
  rescue => e
    puts "[read_base_stats 오류] #{e.message}"
    []
  end

  def read_creature_stats(creature_name)
    creature_name = creature_name.to_s.strip
    return nil if creature_name.empty?

    rows = read("'스탯'!A2:M100")

    row = rows.find do |r|
      r[0].to_s.strip == creature_name || r[1].to_s.strip == creature_name
    end

    unless row
      puts "[read_creature_stats] 스탯 탭에서 #{creature_name} 을(를) 찾지 못했습니다. 기본값 사용"
      return default_creature_stats(creature_name)
    end

    hp = row[4].to_i
    hp = row[1].to_i if hp <= 0 && numeric?(row[1])
    hp = 200 if hp <= 0

    {
      name:    creature_name,
      hp:      hp,
      max_hp:  hp,
      dur:     stat_value(row, 5, 3, 10),
      atk:     stat_value(row, 6, 2, 10),
      agi:     stat_value(row, 7, 4, 0),
      tec:     stat_value(row, 8, 5, 0),
      luck:    stat_value(row, 9, 6, 0),
      pos:     extract_position(row) || 'D4',
      status:  ''
    }
  rescue => e
    puts "[read_creature_stats 오류] #{e.message}"
    default_creature_stats(creature_name)
  end

  def default_creature_stats(name)
    {
      name:    name,
      hp:      200,
      max_hp:  200,
      dur:     10,
      atk:     10,
      agi:     0,
      tec:     0,
      luck:    0,
      pos:     'D4',
      status:  ''
    }
  end

  # ──────────────────────────────────────────────
  # 러너 상태
  #
  # 더 이상 러너현황/맵현황 탭을 쓰지 않습니다.
  # 자동봇 시트 스탯 탭의 E열 건강을 현재 체력으로 읽고/씁니다.
  # 위치는 별도 위치봇/현황 탭이 없으면 기본 D3으로 시작합니다.
  # ──────────────────────────────────────────────

  def read_runner_state
    read_base_stats.map do |stat|
      {
        name:    stat[:name],
        pos:     'D3',
        hp:      stat[:hp].to_i,
        max_hp:  stat[:max_hp].to_i,
        status:  '',
        facing:  stat[:facing].to_s.strip.empty? ? '하' : stat[:facing]
      }
    end
  rescue => e
    puts "[read_runner_state 오류] #{e.message}"
    []
  end

  def update_runner_state(states)
    rows = read("'스탯'!A2:M100")
    return true if rows.empty?

    hp_by_id = states.to_a.each_with_object({}) do |state, h|
      id = state[:name].to_s.strip
      h[id] = state[:hp].to_i unless id.empty?
    end

    values = rows.map do |row|
      id = row[0].to_s.strip
      if hp_by_id.key?(id)
        [hp_by_id[id]]
      else
        [row[4]]
      end
    end

    write("'스탯'!E2:E#{rows.size + 1}", values)
  rescue => e
    puts "[update_runner_state 오류] #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 크리쳐 현황 출력용
  # 현황 탭 2행에 기록: A=이름 / B=위치 / C=HP / D=최대HP
  # E=내구 / F=마법능력 / G=민첩 / H=기술 / I=행운 / J=상태
  # ──────────────────────────────────────────────

  def update_creature_state(creature)
    row = [[
      creature[:name],
      creature[:pos],
      creature[:hp],
      creature[:max_hp],
      creature[:dur],
      creature[:atk],
      creature[:agi],
      creature[:tec],
      creature[:luck],
      creature[:status].to_s
    ]]

    write("'현황'!A2:J2", row)
  rescue => e
    puts "[update_creature_state 오류] #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # HP 바
  # ──────────────────────────────────────────────

  def health_bar(hp, max_hp)
    hp = hp.to_i
    max_hp = max_hp.to_i
    max_hp = 1 if max_hp <= 0

    filled = ((hp.to_f / max_hp) * 10).round
    filled = [[filled, 0].max, 10].min

    empty = 10 - filled
    "█" * filled + "░" * empty + " #{hp}/#{max_hp}"
  end

  private

  def truthy?(value)
    value == true ||
      value.to_s.strip.upcase == 'TRUE' ||
      value.to_s.strip == '1' ||
      value.to_s.strip.upcase == 'ON' ||
      value.to_s.strip == '✓' ||
      value.to_s.strip == '✔'
  end

  def numeric?(value)
    value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
  end

  def stat_value(row, primary_idx, fallback_idx, default_value)
    primary = row[primary_idx].to_i
    return primary if primary != 0

    fallback = row[fallback_idx].to_i
    return fallback if fallback != 0

    default_value
  end

  def extract_position(row)
    row.each do |cell|
      text = cell.to_s.strip.upcase
      return text if text.match?(/\A[A-G][1-8]\z/)
    end
    nil
  end
end
