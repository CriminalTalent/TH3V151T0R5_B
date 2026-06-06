# core/dungeon_battle.rb
# 던전 전투 시스템

require_relative 'dungeon_system'

class DungeonBattle
  def initialize(mastodon_client, sheet_manager)
    @mastodon_client = mastodon_client
    @sheet_manager = sheet_manager
  end
  
  # 전투 시작
  def start_combat(dungeon_id, player_id, enemy_id)
    dungeon = DungeonSystem.get(dungeon_id)
    return { success: false, message: "던전을 찾을 수 없습니다." } unless dungeon
    
    enemy = dungeon[:enemies].find { |e| e[:id] == enemy_id }
    return { success: false, message: "적을 찾을 수 없습니다." } unless enemy
    
    player = @sheet_manager.find_user(player_id)
    return { success: false, message: "플레이어 정보를 찾을 수 없습니다." } unless player
    
    # 전투 판정
    result = execute_combat_round(player, player_id, enemy, dungeon[:raid_mode])
    
    # 적이 쓰러졌는지 확인
    if enemy[:hp] <= 0
      dungeon[:enemies].delete(enemy)
      dungeon[:defeated_enemies] << enemy[:id]
      result[:enemy_defeated] = true
      result[:exp_gained] = enemy[:exp]
      
      # 모든 적 처치 확인
      if dungeon[:enemies].empty?
        result[:dungeon_cleared] = true
      end
    else
      # 적의 반격 (레이드 보스는 멀티 어택)
      if enemy[:multi_attack]
        result[:enemy_counterattacks] = perform_multi_attack(
          dungeon, 
          enemy, 
          player_id,
          enemy[:attack_count]
        )
      else
        counter = perform_enemy_attack(enemy, player, player_id)
        result[:enemy_counterattack] = counter
      end
    end
    
    DungeonSystem.update(dungeon_id, dungeon)
    result
  end
  
  # 플레이어 공격 실행
  def execute_combat_round(player, player_id, enemy, is_raid)
    player_name = player["이름"] || player_id
    
    # 플레이어 공격
    atk = (player["공격"] || 10).to_i
    atk_roll = rand(1..20)
    luck = (player["행운"] || 10).to_i
    
    crit_result = check_critical_hit(luck)
    atk_total = atk + atk_roll
    
    # 적 방어
    def_stat = enemy[:def]
    def_roll = rand(1..20)
    def_total = def_stat + def_roll
    
    damage = [atk_total - def_total, 0].max
    damage = (damage * 1.5).to_i if crit_result[:is_crit]
    
    # 레이드 보스는 데미지 감소
    if is_raid && enemy[:multi_attack]
      damage = (damage * 0.7).to_i # 30% 감소
    end
    
    enemy[:hp] -= damage
    
    {
      success: true,
      player_name: player_name,
      enemy_name: enemy[:name],
      atk_roll: atk_roll,
      atk_stat: atk,
      def_roll: def_roll,
      def_stat: def_stat,
      is_crit: crit_result[:is_crit],
      damage: damage,
      enemy_hp: enemy[:hp],
      enemy_max_hp: enemy[:max_hp]
    }
  end
  
  # 적의 반격
  def perform_enemy_attack(enemy, player, player_id)
    player_name = player["이름"] || player_id
    
    atk_roll = rand(1..20)
    atk_total = enemy[:atk] + atk_roll
    
    def_stat = (player["방어"] || 10).to_i
    def_roll = rand(1..20)
    def_total = def_stat + def_roll
    
    damage = [atk_total - def_total, 0].max
    
    # HP 업데이트
    current_hp = (player["HP"] || 100).to_i
    new_hp = [current_hp - damage, 0].max
    @sheet_manager.update_user(player_id, { hp: new_hp })
    
    {
      enemy_name: enemy[:name],
      player_name: player_name,
      atk_roll: atk_roll,
      atk_stat: enemy[:atk],
      def_roll: def_roll,
      def_stat: def_stat,
      damage: damage,
      player_hp: new_hp,
      player_defeated: new_hp <= 0
    }
  end
  
  # 레이드 보스 멀티 어택
  def perform_multi_attack(dungeon, enemy, attacked_by, attack_count)
    results = []
    
    # 공격 대상 풀 생성 (보스를 공격한 플레이어 우선)
    target_pool = [attacked_by]
    
    # 나머지 살아있는 플레이어 추가
    dungeon[:participants].each do |player_id|
      next if player_id == attacked_by
      player = @sheet_manager.find_user(player_id)
      next unless player
      next if (player["HP"] || 0).to_i <= 0
      
      target_pool << player_id
    end
    
    # 랜덤하게 attack_count만큼 선택
    targets = target_pool.sample([attack_count, target_pool.length].min)
    
    targets.each do |target_id|
      player = @sheet_manager.find_user(target_id)
      next unless player
      
      result = perform_enemy_attack(enemy, player, target_id)
      results << result
    end
    
    results
  end
  
  # 치명타 판정
  def check_critical_hit(luck)
    crit_chance = [luck / 2, 50].min
    roll = rand(1..100)
    
    if roll <= crit_chance
      return { is_crit: true, roll: roll, chance: crit_chance }
    else
      return { is_crit: false, roll: roll, chance: crit_chance }
    end
  end
  
  # 전투 결과 메시지 생성
  def format_combat_message(result)
    lines = []
    
    # 플레이어 공격
    lines << "#{result[:player_name]}의 공격!"
    lines << "판정: #{result[:atk_roll]} + 공격 #{result[:atk_stat]}"
    lines << "[치명타!] (행운 확률 성공)" if result[:is_crit]
    lines << "vs #{result[:enemy_name]} 방어: #{result[:def_roll]} + #{result[:def_stat]}"
    lines << "데미지: #{result[:damage]}"
    lines << "#{result[:enemy_name]} HP: #{result[:enemy_hp]}/#{result[:enemy_max_hp]}"
    
    if result[:enemy_defeated]
      lines << ""
      lines << "#{result[:enemy_name]}을(를) 처치했습니다!"
      lines << "경험치 +#{result[:exp_gained]}"
    else
      # 반격
      if result[:enemy_counterattacks]
        lines << ""
        lines << "#{result[:enemy_name]}의 다중 공격!"
        result[:enemy_counterattacks].each_with_index do |counter, idx|
          lines << ""
          lines << "[대상 #{idx+1}] #{counter[:player_name]}"
          lines << "판정: #{counter[:atk_roll]} + #{counter[:atk_stat]} vs #{counter[:def_roll]} + #{counter[:def_stat]}"
          lines << "데미지: #{counter[:damage]}"
          lines << "#{counter[:player_name]} HP: #{counter[:player_hp]}"
          lines << "#{counter[:player_name]}이(가) 쓰러졌습니다!" if counter[:player_defeated]
        end
      elsif result[:enemy_counterattack]
        counter = result[:enemy_counterattack]
        lines << ""
        lines << "#{counter[:enemy_name]}의 반격!"
        lines << "판정: #{counter[:atk_roll]} + #{counter[:atk_stat]} vs #{counter[:def_roll]} + #{counter[:def_stat]}"
        lines << "데미지: #{counter[:damage]}"
        lines << "#{counter[:player_name]} HP: #{counter[:player_hp]}"
        lines << "#{counter[:player_name]}이(가) 쓰러졌습니다!" if counter[:player_defeated]
      end
    end
    
    if result[:dungeon_cleared]
      lines << ""
      lines << "던전 클리어!"
    end
    
    lines.join("\n")
  end
end
