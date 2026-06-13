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

  # ─── 운영 시트 (OPS) ───────────────────────────────

  # 실행 탭: 1행=헤더, 2행=데이터
  def read_trigger
    rows = read("실행!A2:C2")
    return nil if rows.empty?
    row = rows[0]
    {
      on:    row[0].to_s.upcase == 'TRUE',
      round: row[1].to_i,
      turn:  row[2].to_i   # 1=선공(A팀), 2=후공(B팀)
    }
  end

  def turn_off_trigger
    write("실행!A2", [['FALSE']])
  end

  # 보정 탭: A=이름, B=항목, C=값, D=적용여부, E=메모
  def read_corrections
    rows = read("보정!A2:E50")
    rows.select { |r| r[3].to_s.upcase == 'TRUE' }.map do |r|
      {
        name:  r[0].to_s.strip,
        type:  r[1].to_s.strip,
        value: r[2].to_s.strip,
        memo:  r[4].to_s.strip
      }
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
      @sheet_id,
      "보정!A2:E#{updates.size + 1}",
      body,
      value_input_option: 'RAW'
    )
  rescue => e
    puts "[Sheet 오류] clear_corrections: #{e.message}"
  end

  # 스탯 탭: A=캐릭터명, B=건강, C=마법능력, D=내구도, E=민첩, F=기술, G=행운, H=스킬1, I=스킬2
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

  # 스킬 탭: A=스킬명, B=분류, C=사거리, D=쿨타임, E=설명
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

  # ─── 러너 커맨드 시트 (RUNNER) ──────────────────────

  # A팀 커맨드: M4:U11
  # M=캐릭터명, N=이동위치, O=행동, P~T=대상1~5, U=대상1위치지정
  def read_commands_a
    rows = read("현황!M4:U11")
    parse_commands(rows)
  end

  # B팀 커맨드: M14:U21
  # M=캐릭터명, N=이동위치, O=행동, P~T=대상1~5, U=대상1위치지정
  def read_commands_b
    rows = read("현황!M14:U21")
    parse_commands(rows)
  end

  def read_commands(turn)
    turn == 1 ? read_commands_a : read_commands_b
  end

  # A팀 현황 데이터: O26:S33
  # O=이름, P=위치, Q=위치, R=현재체력, S=최대체력
  def read_current_state_a
    rows = read("현황!O26:S33")
    parse_state_ops(rows)
  end

  # B팀 현황 데이터: O38:S45
  # O=이름, P=위치, Q=위치, R=현재체력, S=최대체력
  def read_current_state_b
    rows = read("현황!O38:S45")
    parse_state_ops(rows)
  end

  def read_current_state(turn)
    turn == 1 ? read_current_state_a : read_current_state_b
  end

  # 현황 업데이트 정산 후
  # A팀 요약: B25:E32 / 데이터: O26:S33
  # B팀 요약: B35:E42 / 데이터: O38:S45
  def update_current_state(states, turn)
    if turn == 1
      update_state_table(states, "현황!B25", "현황!O26")
    else
      update_state_table(states, "현황!B35", "현황!O38")
    end

    update_map(states)
  end

  # 맵 탭 업데이트: C2:J9
  # C~J = A~H열, 2~9행 = 1~8행
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

  private

  def parse_commands(rows)
    rows.map do |r|
      {
        name:       r[0].to_s.strip,
        move_to:    r[1].to_s.strip,
        action:     r[2].to_s.strip,
        targets:    [r[3], r[4], r[5], r[6], r[7]].map { |t| t.to_s.strip }.reject(&:empty?),
        target_pos: r[8].to_s.strip,
        extra:      ''
      }
    end.reject { |r| r[:name].empty? }
  end

  def parse_state(rows)
    rows.map do |r|
      {
        name: r[0].to_s.strip,
        pos:  r[1].to_s.strip,
        hp:   r[2].to_i
      }
    end.reject { |r| r[:name].empty? }
  end

  # O=이름, P=위치, Q=위치, R=현재체력, S=최대체력
  # O26:S33 / O38:S45 기준
  # r[0]=O 이름
  # r[1]=P 위치
  # r[2]=Q 위치
  # r[3]=R 현재체력
  # r[4]=S 최대체력
  def parse_state_ops(rows)
    rows.map do |r|
      pos = r[2].to_s.strip.empty? ? r[1].to_s.strip : r[2].to_s.strip

      {
        name:   r[0].to_s.strip,
        pos:    pos,
        hp:     r[3].to_i,
        max_hp: r[4].to_i
      }
    end.reject { |r| r[:name].empty? }
  end

  def update_state_table(states, summary_range, data_range)
    summary = states.map do |s|
      [
        s[:name],
        s[:hp],
        '',
        s[:pos]
      ]
    end

    write(summary_range, summary)

    # O=이름, P=위치, Q=위치, R=현재체력, S=최대체력
    data = states.map do |s|
      [
        s[:name],
        s[:pos],
        s[:pos],
        s[:hp],
        s[:max_hp] || s[:hp]
      ]
    end

    write(data_range, data)
  end
end
