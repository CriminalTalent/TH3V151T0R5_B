#!/usr/bin/env ruby
# encoding: UTF-8
#
# 사용법: ruby patch_battle_round_v2.rb battle_round.rb
path = ARGV[0] or abort "사용법: ruby patch_battle_round_v2.rb battle_round.rb"
abort "파일을 찾을 수 없습니다: #{path}" unless File.exist?(path)
src = File.read(path)
raw = DATA.read
blocks = raw.split(/^===PATCH \d+===\n/).reject(&:empty?)
patches = blocks.map do |block|
  parts = block.split(/^---NEW---\n/, 2)
  abort "패치 블록 형식 오류 (---NEW--- 구분자 없음)" if parts.size != 2
  old = parts[0].sub(/\A---OLD---\n/, '')
  new = parts[1]
  [old.chomp("\n"), new.chomp("\n")]
end
patches.each_with_index do |(old, new), i|
  count = src.scan(old).size
  if count != 1
    puts "── 패치 #{i + 1} 실패: 대상 문자열이 #{count}번 발견됨 (1번이어야 함) ──"
    puts "찾던 내용:"
    puts old
    abort "중단. 파일이 예상과 다릅니다. 수동 확인 필요."
  end
  src = src.sub(old, new)
  puts "패치 #{i + 1} 적용 완료"
end
File.write(path, src)
puts "\n총 #{patches.size}건 패치 완료 -> #{path}"
__END__
===PATCH 1===
---OLD---
def stat_bonus(ctx, name, stat)
  ctx[:buffs][name].to_a.select { |b| b[:stat] == stat }.sum { |b| b[:value].to_i }
end
---NEW---
def stat_bonus(ctx, name, stat)
  ctx[:buffs][name].to_a.select { |b| b[:stat] == stat }.sum { |b| b[:value].to_i }
end
def cooldown_ready?(ctx, name, skill_name, skill)
  return true if skill[:once]
  cd = skill[:cooldown].to_i
  return true if cd <= 0
  ctx[:cooldowns][name][skill_name].to_i <= 0
end
def prepare_rush_moves!(battle_actions, runner_state, creature, ctx, state_of)
  moves = {}
  battle_actions.each do |name, act|
    skill_name = act[:type]
    skill = BattleSkills.get(skill_name)
    next unless skill && skill[:kind] == :rush
    actor = state_of.call(name)
    next unless actor && actor[:hp].to_i > 0
    next unless cooldown_ready?(ctx, name, skill_name, skill)
    parts = skill_parts(act[:target])
    dest = parts[1].to_s.upcase
    next unless BattleGrid.valid_pos?(dest)
    old_pos = actor[:pos]
    dist = BattleGrid.distance(old_pos, dest).to_i
    multiplier = dist >= 5 ? skill[:long_multiplier] : skill[:multiplier]
    if BattleGrid.line_clear?(old_pos, dest, runner_state, creature, actor_name: name)
      actor[:pos] = dest
      (ctx[:positions] ||= {})[name.to_s] = dest
      moves[name] = { old_pos: old_pos, dest: dest, multiplier: multiplier, moved: true }
    else
      moves[name] = { old_pos: old_pos, dest: dest, multiplier: multiplier, moved: false }
    end
  end
  moves
end
===PATCH 2===
---OLD---
  BattleBossPatterns.apply_ongoing_debuffs!(log, runner_state, ctx)
---NEW---
  BattleBossPatterns.apply_ongoing_debuffs!(log, runner_state, ctx)
  rush_moves = prepare_rush_moves!(battle_actions, runner_state, creature, ctx, state_of)
===PATCH 3===
---OLD---
    if rush_attack
      rush_parts = skill_parts(act[:target])
      dest = rush_parts[1].to_s.upcase
      if BattleGrid.valid_pos?(dest)
        dist = BattleGrid.distance(actor[:pos], dest).to_i
        multiplier = dist >= 5 ? skill[:long_multiplier] : skill[:multiplier]
        if BattleGrid.line_clear?(actor[:pos], dest, runner_state, creature, actor_name: name)
          old_pos = actor[:pos]
          actor[:pos] = dest
          (ctx[:positions] ||= {})[name.to_s] = dest
          log << "#{display_name_of.call(name)}의 습격 이동 #{old_pos} → #{dest}"
        end
      end
    end
---NEW---
    if rush_attack
      info = rush_moves[name]
      if info
        multiplier = info[:multiplier]
        log << "#{display_name_of.call(name)}의 습격 이동 #{info[:old_pos]} → #{info[:dest]}" if info[:moved]
      end
    end
===PATCH 4===
---OLD---
    when :atk_buff_area
      amount = (s[:atk].to_i * skill[:ratio].to_f).ceil
---NEW---
    when :atk_buff_area
      base_amount = s[:atk].to_i + atk_bonus[name]
      amount = (base_amount * skill[:ratio].to_f).ceil
===PATCH 5===
---OLD---
      elsif s[:passive] == '2'
        prev = ctx[:prev_action][name]
        cur  = battle_actions[name]&.dig(:type)
        if prev && cur && prev != cur
          tec_bonus[name] += 10
          passive_lines << "#{display_name_of.call(name)}: [래번클로] 행동 분류 변경 — 기술 +10"
        end
      end
---NEW---
      elsif s[:passive] == '2'
        prev_cat = BattleSkills.category(ctx[:prev_action][name])
        cur_cat  = BattleSkills.category(battle_actions[name]&.dig(:type))
        if prev_cat && cur_cat && prev_cat != cur_cat
          tec_bonus[name] += 10
          passive_lines << "#{display_name_of.call(name)}: [래번클로] 행동 분류 변경 — 기술 +10"
        end
      end
