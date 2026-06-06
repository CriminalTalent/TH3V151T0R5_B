# core/dungeon_system.rb
# 공동목표 시스템 (클라리스 오르 소탕전)

require 'json'

class DungeonSystem
  FLOORS = {
    'B2' => { depth: 2, name: '지하 2층', difficulty: 1 },
    'B3' => { depth: 3, name: '지하 3층', difficulty: 2 },
    'B4' => { depth: 4, name: '지하 4층', difficulty: 3 },
    'B5' => { depth: 5, name: '지하 5층', difficulty: 4 }
  }
  
  # 최대 참가 인원
  MAX_PARTICIPANTS = 30

  # 클라리스 오르이 조직원 종류
  ENEMY_TYPES = {
    # 약한 적 (B2-B3)
    'activist' => {
      name: '순혈주의 활동가',
      hp: 40,
      atk: 3,
      def: 2,
      agi: 3,
      luck: 5,
      exp: 10
    },
    'supporter' => {
      name: '클라리스 지지자',
      hp: 50,
      atk: 4,
      def: 3,
      agi: 4,
      luck: 6,
      exp: 15
    },
    
    # 중간 적 (B3-B4)
    'enforcer' => {
      name: '혈통차별 집행자',
      hp: 70,
      atk: 5,
      def: 4,
      agi: 5,
      luck: 8,
      exp: 25
    },
    'officer' => {
      name: '클라리스 간부',
      hp: 90,
      atk: 6,
      def: 5,
      agi: 6,
      luck: 10,
      exp: 35
    },
    
    # 강한 적 (B4-B5)
    'elite' => {
      name: '정예 순혈주의자',
      hp: 120,
      atk: 8,
      def: 6,
      agi: 7,
      luck: 12,
      exp: 50
    },
    'commander' => {
      name: '클라리스 사령관',
      hp: 150,
      atk: 10,
      def: 8,
      agi: 8,
      luck: 15,
      exp: 75
    },
    
    # 레이드 보스
    'boss' => {
      name: '클라리스 오르이 핵심인물',
      hp: 300,
      atk: 12,
      def: 10,
      agi: 10,
      luck: 20,
      exp: 200,
      multi_attack: true,
      attack_count: 3 # 한 턴에 3명 공격 가능
    }
  }

  @dungeons = {} # dungeon_id => dungeon_state
  @mutex = Mutex.new

  class << self
    # 공동목표 생성
    def create(participants, floor_code, raid_mode: false)
      @mutex.synchronize do
        dungeon_id = generate_dungeon_id(participants, floor_code)
        
        floor_info = FLOORS[floor_code]
        return nil unless floor_info
        
        # 참가자 수 제한 확인
        if participants.length > MAX_PARTICIPANTS
          return nil
        end
        
        # 8x8 맵 생성
        map = Array.new(8) { Array.new(8) { nil } }
        
        # 참가자들을 맵 하단에 배치 (8명씩 행으로 배치)
        participants.each_with_index do |player_id, idx|
          # 8명씩 나눠서 y좌표 결정 (하단부터)
          row = idx / 8
          col = idx % 8
          y = 7 - row # 하단부터 위로
          
          # 맵 범위를 벗어나면 대기 큐에 추가
          if y >= 0
            map[y][col] = { type: 'player', id: player_id }
          end
        end
        
        # 적 배치
        enemy_count = raid_mode ? 1 : [1, 2].sample
        enemies = []
        
        enemy_count.times do |i|
          enemy_type = select_enemy_type(floor_info[:difficulty], raid_mode)
          enemy_data = ENEMY_TYPES[enemy_type].dup
          enemy_id = "enemy_#{i+1}"
          
          # 적을 맵 상단(y=0~2)에 랜덤 배치
          loop do
            x = rand(0..7)
            y = rand(0..2)
            
            if map[y][x].nil?
              map[y][x] = { type: 'enemy', id: enemy_id }
              enemies << {
                id: enemy_id,
                type: enemy_type,
                name: enemy_data[:name],
                hp: enemy_data[:hp],
                max_hp: enemy_data[:hp],
                atk: enemy_data[:atk],
                def: enemy_data[:def],
                agi: enemy_data[:agi],
                luck: enemy_data[:luck],
                exp: enemy_data[:exp],
                position: { x: x, y: y },
                multi_attack: enemy_data[:multi_attack] || false,
                attack_count: enemy_data[:attack_count] || 1
              }
              break
            end
          end
        end
        
        @dungeons[dungeon_id] = {
          dungeon_id: dungeon_id,
          floor: floor_code,
          floor_name: floor_info[:name],
          difficulty: floor_info[:difficulty],
          raid_mode: raid_mode,
          participants: participants,
          map: map,
          enemies: enemies,
          turn: 0,
          phase: 'movement', # movement or combat
          current_player: participants.first,
          defeated_enemies: [],
          total_participants: participants.length,
          created_at: Time.now
        }
        
        dungeon_id
      end
    end
    
    # 던전 조회
    def get(dungeon_id)
      @mutex.synchronize do
        @dungeons[dungeon_id]
      end
    end
    
    # 플레이어로 던전 찾기
    def find_by_player(player_id)
      @mutex.synchronize do
        @dungeons.values.find { |d| d[:participants].include?(player_id) }
      end
    end
    
    # 던전 업데이트
    def update(dungeon_id, updates)
      @mutex.synchronize do
        if @dungeons[dungeon_id]
          @dungeons[dungeon_id].merge!(updates)
        end
      end
    end
    
    # 던전 종료
    def clear(dungeon_id)
      @mutex.synchronize do
        @dungeons.delete(dungeon_id)
      end
    end
    
    # 플레이어 이동
    def move_player(dungeon_id, player_id, direction)
      dungeon = get(dungeon_id)
      return nil unless dungeon
      
      # 현재 위치 찾기
      current_pos = find_player_position(dungeon[:map], player_id)
      return nil unless current_pos
      
      # 방향에 따른 이동
      dx, dy = get_direction_delta(direction)
      new_x = current_pos[:x] + dx
      new_y = current_pos[:y] + dy
      
      # 유효성 검사
      return nil if new_x < 0 || new_x > 7 || new_y < 0 || new_y > 7
      return nil if dungeon[:map][new_y][new_x] # 이미 점유됨
      
      # 이동 실행
      dungeon[:map][current_pos[:y]][current_pos[:x]] = nil
      dungeon[:map][new_y][new_x] = { type: 'player', id: player_id }
      
      # 적과 인접했는지 확인
      adjacent_enemy = find_adjacent_enemy(dungeon[:map], new_x, new_y)
      
      update(dungeon_id, dungeon)
      
      {
        moved: true,
        new_pos: { x: new_x, y: new_y },
        adjacent_enemy: adjacent_enemy
      }
    end
    
    # 맵 렌더링 (텍스트)
    def render_map(dungeon_id)
      dungeon = get(dungeon_id)
      return nil unless dungeon
      
      map = dungeon[:map]
      lines = []
      
      lines << "#{dungeon[:floor_name]} (#{dungeon[:raid_mode] ? '레이드' : '공동목표'})"
      lines << "참가자: #{dungeon[:total_participants]}명"
      lines << "=" * 24
      lines << ""
      
      # 좌표 표시 (상단)
      lines << "  " + (0..7).map { |x| x.to_s }.join(' ')
      
      map.each_with_index do |row, y|
        line = "#{y} "
        row.each do |cell|
          if cell.nil?
            line += ". "
          elsif cell[:type] == 'player'
            line += "P "
          elsif cell[:type] == 'enemy'
            line += "E "
          end
        end
        lines << line
      end
      
      lines << ""
      lines << "P: 플레이어 | E: 적"
      lines.join("\n")
    end
    
    # 맵 상태 요약
    def get_status(dungeon_id)
      dungeon = get(dungeon_id)
      return nil unless dungeon
      
      player_positions = []
      dungeon[:participants].each do |player_id|
        pos = find_player_position(dungeon[:map], player_id)
        player_positions << { id: player_id, pos: pos }
      end
      
      enemy_positions = []
      dungeon[:enemies].each do |enemy|
        enemy_positions << {
          id: enemy[:id],
          name: enemy[:name],
          hp: "#{enemy[:hp]}/#{enemy[:max_hp]}",
          pos: enemy[:position]
        }
      end
      
      {
        floor: dungeon[:floor_name],
        turn: dungeon[:turn],
        phase: dungeon[:phase],
        players: player_positions,
        enemies: enemy_positions,
        defeated: dungeon[:defeated_enemies].length
      }
    end
    
    private
    
    def generate_dungeon_id(participants, floor_code)
      sorted = participants.sort.join('_')
      timestamp = Time.now.to_i
      "dungeon_#{floor_code}_#{sorted}_#{timestamp}"
    end
    
    def select_enemy_type(difficulty, raid_mode)
      if raid_mode
        return 'boss'
      end
      
      case difficulty
      when 1
        ['activist', 'activist', 'supporter'].sample
      when 2
        ['supporter', 'enforcer', 'enforcer'].sample
      when 3
        ['enforcer', 'officer', 'elite'].sample
      when 4
        ['officer', 'elite', 'elite', 'commander'].sample
      else
        'activist'
      end
    end
    
    def find_player_position(map, player_id)
      map.each_with_index do |row, y|
        row.each_with_index do |cell, x|
          if cell && cell[:type] == 'player' && cell[:id] == player_id
            return { x: x, y: y }
          end
        end
      end
      nil
    end
    
    def find_adjacent_enemy(map, x, y)
      # 8방향 검사 (상하좌우 + 대각선)
      deltas = [
        [-1, -1], [0, -1], [1, -1],
        [-1,  0],          [1,  0],
        [-1,  1], [0,  1], [1,  1]
      ]
      
      deltas.each do |dx, dy|
        nx = x + dx
        ny = y + dy
        next if nx < 0 || nx > 7 || ny < 0 || ny > 7
        
        cell = map[ny][nx]
        if cell && cell[:type] == 'enemy'
          return cell[:id]
        end
      end
      
      nil
    end
    
    def get_direction_delta(direction)
      case direction.downcase
      when '상', 'w', 'up'
        [0, -1]
      when '하', 's', 'down'
        [0, 1]
      when '좌', 'a', 'left'
        [-1, 0]
      when '우', 'd', 'right'
        [1, 0]
      when '좌상', 'q'
        [-1, -1]
      when '우상', 'e'
        [1, -1]
      when '좌하', 'z'
        [-1, 1]
      when '우하', 'c'
        [1, 1]
      else
        [0, 0]
      end
    end
  end
end
