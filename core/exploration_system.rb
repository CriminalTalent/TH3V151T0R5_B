# core/exploration_system.rb
# 개인/협력 탐색 시스템 - 클라리스 오르 조직 소탕

require 'json'

class ExplorationSystem
  # 맵 정보
  MAPS = {
    'B2' => { 
      name: '지하 2층', 
      difficulty: 1,
      investigation_type: '조사',
      encounter_rate: 30,  # 몹 조우 확률 30%
      item_rate: 20        # 아이템 발견 확률 20%
    },
    'B3' => { 
      name: '지하 3층', 
      difficulty: 2,
      investigation_type: '정밀조사',
      encounter_rate: 35,
      item_rate: 15
    },
    'B4' => { 
      name: '지하 4층', 
      difficulty: 3,
      investigation_type: '감지',
      encounter_rate: 40,
      item_rate: 10
    },
    'B5' => { 
      name: '지하 5층', 
      difficulty: 4,
      investigation_type: '훔쳐보기',
      encounter_rate: 45,
      item_rate: 8
    }
  }

  # 클라리스 오르 조직원
  ENEMIES = {
    1 => ['순혈주의 활동가', '클라리스 지지자'],
    2 => ['클라리스 지지자', '혈통차별 집행자'],
    3 => ['혈통차별 집행자', '클라리스 간부', '정예 순혈주의자'],
    4 => ['클라리스 간부', '정예 순혈주의자', '클라리스 사령관']
  }

  ENEMY_STATS = {
    '순혈주의 활동가' => { hp: 40, atk: 3, def: 2, agi: 3, luck: 5, exp: 10 },
    '클라리스 지지자' => { hp: 50, atk: 4, def: 3, agi: 4, luck: 6, exp: 15 },
    '혈통차별 집행자' => { hp: 70, atk: 5, def: 4, agi: 5, luck: 8, exp: 25 },
    '클라리스 간부' => { hp: 90, atk: 6, def: 5, agi: 6, luck: 10, exp: 35 },
    '정예 순혈주의자' => { hp: 120, atk: 8, def: 6, agi: 7, luck: 12, exp: 50 },
    '클라리스 사령관' => { hp: 150, atk: 10, def: 8, agi: 8, luck: 15, exp: 75 }
  }

  # 파밍 가능 아이템
  FARMABLE_ITEMS = {
    1 => ['소형물약', '낡은 지도', '조직 배지'],
    2 => ['중형물약', '암호문서', '마법 촉매', '조직 배지'],
    3 => ['중형물약', '대형물약', '비밀 열쇠', '마법서 조각', '순혈주의 선언문'],
    4 => ['대형물약', '전설의 유물', '고급 마법서', '핵심인물 서신']
  }

  @explorations = {}  # exploration_id => state
  @mutex = Mutex.new

  class << self
    attr_reader :explorations

    # 탐색 시작 (개인 또는 협력)
    def start_exploration(participants, floor_code, thread_id, sheet_manager: nil)
      @mutex.synchronize do
        map_info = MAPS[floor_code]
        return nil unless map_info

        exploration_id = generate_exploration_id(participants, floor_code, thread_id)

        # 이미 진행 중인 탐색 확인
        existing = @explorations.values.find do |exp| 
          exp[:participants].any? { |p| participants.include?(p) } && exp[:active]
        end

        return { error: '이미 탐색 중입니다' } if existing

        @explorations[exploration_id] = {
          exploration_id: exploration_id,
          thread_id: thread_id,
          floor: floor_code,
          floor_name: map_info[:name],
          difficulty: map_info[:difficulty],
          investigation_type: map_info[:investigation_type],
          encounter_rate: map_info[:encounter_rate],
          item_rate: map_info[:item_rate],
          participants: participants,
          position: 'entrance',  # 항상 입구에서 시작
          steps: 0,
          discovered_clues: [],
          found_items: [],
          defeated_enemies: [],
          current_encounter: nil,
          active: true,
          sheet_manager: sheet_manager,
          created_at: Time.now
        }

        exploration_id
      end
    end

    # 탐색 진행 (한 걸음)
    def explore_step(exploration_id, user_id)
      exploration = get(exploration_id)
      return nil unless exploration
      return { error: '권한이 없습니다' } unless exploration[:participants].include?(user_id)
      return { error: '전투 중입니다' } if exploration[:current_encounter]

      exploration[:steps] += 1

      result = {
        step: exploration[:steps],
        position: generate_random_position,
        events: []
      }

      # 1. 단서 발견 판정 (조사 시트 연동)
      clue_result = check_clue_discovery(exploration, user_id)
      if clue_result
        result[:events] << { type: 'clue', data: clue_result }
        exploration[:discovered_clues] << clue_result
      end

      # 2. 아이템 파밍 판정
      item_result = check_item_farming(exploration)
      if item_result
        result[:events] << { type: 'item', data: item_result }
        exploration[:found_items] << item_result
      end

      # 3. 적 조우 판정
      encounter_result = check_enemy_encounter(exploration)
      if encounter_result
        result[:events] << { type: 'encounter', data: encounter_result }
        exploration[:current_encounter] = encounter_result
      end

      exploration[:position] = result[:position]
      update(exploration_id, exploration)

      result
    end

    # 전투 시작 (조우한 적)
    def start_encounter_battle(exploration_id, user_id)
      exploration = get(exploration_id)
      return nil unless exploration
      return { error: '권한이 없습니다' } unless exploration[:participants].include?(user_id)
      return { error: '조우한 적이 없습니다' } unless exploration[:current_encounter]

      encounter = exploration[:current_encounter]
      
      {
        exploration_id: exploration_id,
        enemy: encounter,
        participants: exploration[:participants]
      }
    end

    # 전투 종료 처리
    def end_encounter(exploration_id, victory: false)
      exploration = get(exploration_id)
      return nil unless exploration

      if victory
        enemy = exploration[:current_encounter]
        exploration[:defeated_enemies] << {
          name: enemy[:name],
          defeated_at: Time.now
        }
      end

      exploration[:current_encounter] = nil
      update(exploration_id, exploration)
    end

    # 탐색 종료
    def end_exploration(exploration_id)
      exploration = get(exploration_id)
      return nil unless exploration

      exploration[:active] = false
      exploration[:ended_at] = Time.now

      summary = {
        floor: exploration[:floor_name],
        participants: exploration[:participants],
        steps: exploration[:steps],
        clues_found: exploration[:discovered_clues].size,
        items_found: exploration[:found_items].size,
        enemies_defeated: exploration[:defeated_enemies].size,
        duration: (exploration[:ended_at] - exploration[:created_at]).to_i
      }

      update(exploration_id, exploration)
      summary
    end

    def get(exploration_id)
      @mutex.synchronize do
        @explorations[exploration_id]
      end
    end

    def find_by_user(user_id)
      @mutex.synchronize do
        @explorations.values.find do |exp|
          exp[:participants].include?(user_id) && exp[:active]
        end
      end
    end

    def find_by_thread(thread_id)
      @mutex.synchronize do
        @explorations.values.find do |exp|
          exp[:thread_id] == thread_id && exp[:active]
        end
      end
    end

    def update(exploration_id, updates)
      @mutex.synchronize do
        if @explorations[exploration_id]
          @explorations[exploration_id].merge!(updates)
        end
      end
    end

    private

    def generate_exploration_id(participants, floor_code, thread_id)
      sorted = participants.sort.join('_')
      timestamp = Time.now.to_i
      "explore_#{floor_code}_#{thread_id}_#{timestamp}"
    end

    def generate_random_position
      areas = [
        '긴 복도', '어두운 방', '계단 근처', '갈림길',
        '넓은 홀', '좁은 통로', '비밀 공간', '폐쇄된 구역',
        '오래된 창고', '감시실', '회의실 흔적', '작전실'
      ]
      areas.sample
    end

    # 단서 발견 (조사 시트 연동)
    def check_clue_discovery(exploration, user_id)
      sheet_manager = exploration[:sheet_manager]
      return nil unless sheet_manager

      # 층별 발견 확률 (스탭마다)
      base_rate = case exploration[:difficulty]
                  when 1 then 25
                  when 2 then 20
                  when 3 then 15
                  when 4 then 10
                  else 20
                  end

      return nil if rand(100) >= base_rate

      # 조사 시트에서 해당 층의 단서 조회
      target = "#{exploration[:floor_name]} 단서"
      investigation_type = exploration[:investigation_type]
      entry = sheet_manager.find_investigation_entry(target, investigation_type)

      unless entry
        # 기본 단서
        return {
          target: target,
          result: "클라리스 오르 조직의 활동 흔적을 발견했습니다.",
          success: true,
          is_default: true,
          discovered_by: user_id
        }
      end

      # 플레이어 행운
      user = sheet_manager.find_user(user_id)
      luck = (user["행운"] || 10).to_i

      # 판정
      dice = rand(1..20)
      difficulty = entry["난이도"].to_i
      total = dice + luck
      success = total >= difficulty

      result_text = success ? entry["성공결과"] : entry["실패결과"]

      clue = {
        target: target,
        dice: dice,
        luck: luck,
        total: total,
        difficulty: difficulty,
        success: success,
        result: result_text,
        discovered_by: user_id
      }

      # 로그 기록
      sheet_manager.log_investigation(
        user_id,
        exploration[:floor_name],
        target,
        investigation_type,
        success,
        result_text
      )

      clue
    end

    # 아이템 파밍
    def check_item_farming(exploration)
      item_rate = exploration[:item_rate]
      return nil if rand(100) >= item_rate

      difficulty = exploration[:difficulty]
      items = FARMABLE_ITEMS[difficulty] || FARMABLE_ITEMS[1]
      item_name = items.sample

      {
        name: item_name,
        floor: exploration[:floor_name],
        found_at: Time.now
      }
    end

    # 적 조우
    def check_enemy_encounter(exploration)
      encounter_rate = exploration[:encounter_rate]
      return nil if rand(100) >= encounter_rate

      difficulty = exploration[:difficulty]
      enemy_names = ENEMIES[difficulty] || ENEMIES[1]
      enemy_name = enemy_names.sample
      stats = ENEMY_STATS[enemy_name]

      {
        name: enemy_name,
        full_name: "클라리스 오르 #{enemy_name}",
        hp: stats[:hp],
        max_hp: stats[:hp],
        atk: stats[:atk],
        def: stats[:def],
        agi: stats[:agi],
        luck: stats[:luck],
        exp: stats[:exp],
        encountered_at: Time.now
      }
    end
  end
end
