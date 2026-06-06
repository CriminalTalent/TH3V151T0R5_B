# core/mas_raid.rb
# 마스레이드 맵 시스템
# 이동: 상하좌우만, 최대 5칸, 1칸당 행동력 1 소모
# 같은 칸: 아군 통과 가능, 적군 통과 불가, 같은 칸 2명 이상 불가

class MasRaid
  MAX_MOVE = 5

  @raids = {}
  @mutex = Mutex.new

  class << self
    def create(team1, team2, map_size: 20)
      raid_id = "raid_#{Time.now.to_i}_#{rand(9999)}"
      map     = Array.new(map_size) { Array.new(map_size, nil) }

      # 팀1 하단, 팀2 상단 배치
      team1.each_with_index do |uid, i|
        x = i % map_size
        y = map_size - 1 - (i / map_size)
        map[y][x] = { type: :player, id: uid, team: :team1 }
      end
      team2.each_with_index do |uid, i|
        x = i % map_size
        y = i / map_size
        map[y][x] = { type: :player, id: uid, team: :team2 }
      end

      state = {
        raid_id:   raid_id,
        team1:     team1,
        team2:     team2,
        map:       map,
        map_size:  map_size
      }

      @mutex.synchronize { @raids[raid_id] = state }
      raid_id
    end

    def get(raid_id)
      @mutex.synchronize { @raids[raid_id] }
    end

    def update(raid_id, state)
      @mutex.synchronize { @raids[raid_id] = state }
    end

    def clear(raid_id)
      @mutex.synchronize { @raids.delete(raid_id) }
    end

    def find_by_player(user_id)
      @mutex.synchronize do
        @raids.values.find { |s| s[:team1].include?(user_id) || s[:team2].include?(user_id) }
      end
    end

    # 이동 처리
    # direction: "상" / "하" / "좌" / "우"
    # steps: 1~5
    # 반환: { moved:, new_pos:, error: }
    def move_player(raid_id, user_id, direction, steps, ap_available)
      state    = get(raid_id)
      return { error: "레이드를 찾을 수 없습니다." } unless state

      steps = [[steps.to_i, 1].max, MAX_MOVE].min

      # 대각선 입력 거부
      dx, dy = direction_delta(direction)
      return { error: "대각선 이동 불가. 상/하/좌/우만 이동 가능합니다." } if dx != 0 && dy != 0
      return { error: "유효하지 않은 방향입니다." } if dx == 0 && dy == 0

      # 행동력 확인
      if ap_available < steps
        return { error: "행동력 부족. (필요 #{steps} / 현재 #{ap_available})" }
      end

      pos = find_pos(state[:map], user_id)
      return { error: "위치를 찾을 수 없습니다." } unless pos

      cur_x, cur_y = pos[:x], pos[:y]
      moved = 0
      map_size = state[:map_size]
      my_team  = state[:team1].include?(user_id) ? :team1 : :team2

      steps.times do
        nx = cur_x + dx
        ny = cur_y + dy

        # 맵 범위 초과
        break if nx < 0 || nx >= map_size || ny < 0 || ny >= map_size

        cell = state[:map][ny][nx]

        if cell
          if cell[:team] != my_team
            # 적군 칸 — 통과 불가, 멈춤
            break
          else
            # 아군 칸 — 통과 가능하지만 같은 칸에 서지 않음 (최종 위치에만 해당)
            # 마지막 칸이면 막힘, 중간이면 통과
            if moved == steps - 1
              break
            end
          end
        end

        state[:map][cur_y][cur_x] = nil
        state[:map][ny][nx] = { type: :player, id: user_id, team: my_team }
        cur_x = nx
        cur_y = ny
        moved += 1
      end

      update(raid_id, state)
      { moved: moved, new_pos: { x: cur_x, y: cur_y } }
    end

    # 맵 렌더링
    def render_map(raid_id)
      state = get(raid_id)
      return nil unless state

      map_size = state[:map_size]
      lines    = []

      # 상단 좌표
      lines << "   " + (0...map_size).map { |x| x.to_s.rjust(2) }.join(" ")

      state[:map].each_with_index do |row, y|
        line = y.to_s.rjust(2) + " "
        row.each do |cell|
          if cell.nil?
            line += " . "
          elsif cell[:team] == :team1
            line += " A "
          elsif cell[:team] == :team2
            line += " B "
          else
            line += " ? "
          end
        end
        lines << line
      end

      lines << "A=팀1(선공) B=팀2(후공)"
      lines.join("\n")
    end

    # 플레이어 위치 조회
    def player_pos(raid_id, user_id)
      state = get(raid_id)
      return nil unless state
      find_pos(state[:map], user_id)
    end

    private

    def find_pos(map, user_id)
      map.each_with_index do |row, y|
        row.each_with_index do |cell, x|
          return { x: x, y: y } if cell && cell[:id] == user_id
        end
      end
      nil
    end

    def direction_delta(dir)
      case dir.to_s
      when "상", "up",    "u" then [0, -1]
      when "하", "down",  "d" then [0,  1]
      when "좌", "left",  "l" then [-1, 0]
      when "우", "right", "r" then [1,  0]
      else [0, 0]
      end
    end
  end
end
