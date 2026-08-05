#!/usr/bin/env ruby
# encoding: UTF-8
#
# 사용법: ruby patch_indomitable.rb <파일명>
# 그 파일에 해당하는 패치만 골라서 적용합니다.
path = ARGV[0] or abort "사용법: ruby patch_indomitable.rb <파일명>"
abort "파일을 찾을 수 없습니다: #{path}" unless File.exist?(path)
target_base = File.basename(path)
src = File.read(path)
raw = DATA.read
blocks = raw.split(/^===PATCH \d+ FILE=([^\s=]+)===\n/)
blocks.shift
pairs = blocks.each_slice(2).to_a
applied = 0
skipped = 0
pairs.each_with_index do |(file_tag, block), i|
  unless file_tag == target_base
    skipped += 1
    next
  end
  parts = block.split(/^---NEW---\n/, 2)
  abort "패치 #{i + 1} 형식 오류 (---NEW--- 없음)" if parts.size != 2
  old = parts[0].sub(/\A---OLD---\n/, '').chomp("\n")
  new = parts[1].chomp("\n")
  count = src.scan(old).size
  if count != 1
    puts "── #{file_tag} 패치 실패: 대상 문자열이 #{count}번 발견됨 (1번이어야 함) ──"
    puts "찾던 내용:"
    puts old
    abort "중단. 파일이 예상과 다릅니다."
  end
  src = src.sub(old, new)
  applied += 1
  puts "#{file_tag} 패치 적용 완료 (#{applied}번째)"
end
if applied.zero?
  puts "#{target_base}에 해당하는 패치가 없습니다 (다른 파일 대상 패치 #{skipped}건은 건너뜀)."
else
  File.write(path, src)
  puts "\n#{target_base}: 총 #{applied}건 패치 완료 -> #{path}"
end
__END__
===PATCH 1 FILE=battle_util.rb===
---OLD---
    survive_once: {},
    survive_penalty: {},
---NEW---
    survive_once: {},
    indomitable_buffer: Hash.new(0),
===PATCH 2 FILE=main.rb===
---OLD---
  if ctx[:survive_penalty] && ctx[:survive_penalty].any?
    ctx[:survive_penalty].each_key do |name|
      next unless session.runner_names.include?(name)
      next if session.dead_runners.to_a.include?(name)
      session.actions[name] = { type: '필사즉생 후유증', target: '' }
    end
    ctx[:survive_penalty] = {}
  end
---NEW---
===PATCH 3 FILE=battle_boss_patterns.rb===
---OLD---
  def apply_pattern_damage_to_runner!(log, runner, creature, raw_power, debuff, ctx, stats_of:, dur_bonus:, defended_multiplier:, shields:, took_damage:, agi_bonus: nil, runner_state: nil)
---NEW---
  def apply_pattern_damage_to_runner!(log, runner, creature, raw_power, debuff, ctx, stats_of:, dur_bonus:, defended_multiplier:, shields:, took_damage:, agi_bonus: nil, runner_state: nil, multi_target: false)
===PATCH 4 FILE=battle_boss_patterns.rb===
---OLD---
    if !redirected && ctx[:survive_once] && runner_state
      # 지정 커버(희생)가 없으면, 이번 라운드 필사즉생을 쓴 사람이 있을 경우
      # 대신 맞아준다 (파티 전체를 대상으로 하는 공격도 전부 흡수).
      guardian_name = ctx[:survive_once].to_a.find { |_n, active| active }&.first
      if guardian_name && guardian_name.to_s != name.to_s
        guardian_runner = runner_state.find { |r| r[:name].to_s == guardian_name.to_s }
        if guardian_runner && guardian_runner[:hp].to_i > 0
          guardian_dname = guardian_runner[:display_name].to_s.strip
          guardian_dname = guardian_name.to_s if guardian_dname.empty?
          log << "#{guardian_dname} → [필사즉생] #{dname} 대신 피격"
          runner = guardian_runner
          name = runner[:name]
          dname = guardian_dname
        end
      end
    end
---NEW---
    if !redirected && multi_target && ctx[:survive_once] && runner_state
      # 다인 대상 공격(전체공격/범위공격/지정공격다인)만 필사즉생이 흡수한다.
      # 회피 판정 없이 무조건 흡수하며, 위력은 즉시 정산하지 않고 버퍼에 모아뒀다가
      # 라운드 종료 시 유효 내구도를 1번만 적용해 최종 피해를 계산한다.
      guardian_name = ctx[:survive_once].to_a.find { |_n, active| active }&.first
      if guardian_name
        guardian_runner = runner_state.find { |r| r[:name].to_s == guardian_name.to_s }
        if guardian_runner && guardian_runner[:hp].to_i > 0
          guardian_dname = guardian_runner[:display_name].to_s.strip
          guardian_dname = guardian_name.to_s if guardian_dname.empty?
          ctx[:indomitable_buffer][guardian_name] = ctx[:indomitable_buffer][guardian_name].to_i + raw_power.to_i
          log << "#{guardian_dname} → [필사즉생] #{dname} 대신 흡수 (판정은 라운드 종료 시 일괄 정산)"
          log << ''
          return 0
        end
      end
    end
===PATCH 5 FILE=battle_boss_patterns.rb===
---OLD---
    # 필사즉생: 이번 턴 건강이 0 이하로 떨어지는 것을 방지 (라운드가 끝날 때까지
    # 몇 번을 대신 맞든 계속 보호되며, 라운드 종료 시 1회 소모로 초기화된다).
    if ctx[:survive_once] && ctx[:survive_once][name] && runner[:hp].to_i - dmg <= 0 && dmg > 0
      overkill = dmg > runner[:hp].to_i
      dmg = runner[:hp].to_i - 1
      log << "#{dname}: 필사즉생으로 건강 0 이하 방지"
      if overkill && !(stats[:house].to_s.strip == '후플푸프' && stats[:passive].to_s == '2')
        ctx[:survive_penalty] ||= {}
        ctx[:survive_penalty][name] = true
        log << "#{dname}: 받은 피해가 잔여 건강을 초과하여 다음 라운드 행동할 수 없습니다"
      elsif overkill
        log << "#{dname}: [후플푸프] 필사즉생 후유증 면제 — 다음 라운드도 정상 행동 가능"
      end
    end

    runner[:hp] = [runner[:hp].to_i - dmg, 0].max
---NEW---
    runner[:hp] = [runner[:hp].to_i - dmg, 0].max
===PATCH 6 FILE=battle_boss_patterns.rb===
---OLD---
        targets.each do |runner|
          apply_pattern_damage_to_runner!(
            log, runner, creature, raw_power, debuff, ctx,
            stats_of: stats_of,
            dur_bonus: dur_bonus,
            defended_multiplier: defended_multiplier,
            shields: shields,
            took_damage: took_damage,
            agi_bonus: agi_bonus,
            runner_state: runner_state
          )
        end
      end

      return true
    end

    if name == '디버프' || category == '디버프'
---NEW---
        targets.each do |runner|
          apply_pattern_damage_to_runner!(
            log, runner, creature, raw_power, debuff, ctx,
            stats_of: stats_of,
            dur_bonus: dur_bonus,
            defended_multiplier: defended_multiplier,
            shields: shields,
            took_damage: took_damage,
            agi_bonus: agi_bonus,
            runner_state: runner_state,
            multi_target: true
          )
        end
      end

      return true
    end

    if name == '디버프' || category == '디버프'
===PATCH 7 FILE=battle_boss_patterns.rb===
---OLD---
    if cells.any?
      targets = targets_by_cells(runner_state, cells)
      range_label = range_text(cells)
    elsif !target_name.empty?
      targets = targets_by_name(runner_state, target_name)
      range_label = target_name
    elsif name == '지정공격다인'
      targets = random_targets(runner_state, target_count(creature))
      range_label = targets.map { |t| t[:name].to_s }.join(', ')
    else
      targets = random_targets(runner_state, 1)
      range_label = targets.map { |t| t[:name].to_s }.join(', ')
    end

    log_skill_header(log, creature, name, raw_power, range_label, debuff)

    if targets.empty?
      log << '대상 없음'
      log << '피해 없음'
    else
      targets.each do |runner|
        apply_pattern_damage_to_runner!(
          log, runner, creature, raw_power, debuff, ctx,
          stats_of: stats_of,
          dur_bonus: dur_bonus,
          defended_multiplier: defended_multiplier,
          shields: shields,
          took_damage: took_damage,
          agi_bonus: agi_bonus,
          runner_state: runner_state
        )
      end
    end

    true
  end
end
---NEW---
    multi_target = false
    if cells.any?
      targets = targets_by_cells(runner_state, cells)
      range_label = range_text(cells)
      multi_target = true
    elsif !target_name.empty?
      targets = targets_by_name(runner_state, target_name)
      range_label = target_name
    elsif name == '지정공격다인'
      targets = random_targets(runner_state, target_count(creature))
      range_label = targets.map { |t| t[:name].to_s }.join(', ')
      multi_target = true
    else
      targets = random_targets(runner_state, 1)
      range_label = targets.map { |t| t[:name].to_s }.join(', ')
    end

    log_skill_header(log, creature, name, raw_power, range_label, debuff)

    if targets.empty?
      log << '대상 없음'
      log << '피해 없음'
    else
      targets.each do |runner|
        apply_pattern_damage_to_runner!(
          log, runner, creature, raw_power, debuff, ctx,
          stats_of: stats_of,
          dur_bonus: dur_bonus,
          defended_multiplier: defended_multiplier,
          shields: shields,
          took_damage: took_damage,
          agi_bonus: agi_bonus,
          runner_state: runner_state,
          multi_target: multi_target
        )
      end
    end

    true
  end
end
===PATCH 8 FILE=battle_round.rb===
---OLD---
        cover_name = ctx[:cover][target[:name]]
        cover = state_of.call(cover_name) if cover_name
        if cover && cover[:hp].to_i > 0
          target = cover
        else
          # 지정 커버(희생)가 없으면, 이번 라운드 필사즉생을 쓴 사람이
          # 있을 경우 대신 맞아준다 (파티 전체 대상 공격 흡수).
          guardian_name = ctx[:survive_once].to_a.find { |_n, active| active }&.first
          if guardian_name && guardian_name.to_s != target[:name].to_s
            guardian = state_of.call(guardian_name)
            target = guardian if guardian && guardian[:hp].to_i > 0
          end
        end
        tname = target[:name]
---NEW---
        cover_name = ctx[:cover][target[:name]]
        cover = state_of.call(cover_name) if cover_name
        target = cover if cover && cover[:hp].to_i > 0
        tname = target[:name]
===PATCH 9 FILE=battle_round.rb===
---OLD---
            if ctx[:survive_once][tname] && target[:hp].to_i - dmg <= 0 && dmg > 0
              overkill = dmg > target[:hp].to_i
              dmg = target[:hp].to_i - 1
              log << "#{display_name_of.call(tname)}: 필사즉생으로 건강 0 이하 방지"
              if overkill && !(ts[:house].to_s.strip == '후플푸프' && ts[:passive].to_s == '2')
                ctx[:survive_penalty] ||= {}
                ctx[:survive_penalty][tname] = true
                log << "#{display_name_of.call(tname)}: 받은 피해가 잔여 건강을 초과하여 다음 라운드 행동할 수 없습니다"
              elsif overkill
                log << "#{display_name_of.call(tname)}: [후플푸프] 필사즉생 후유증 면제 — 다음 라운드도 정상 행동 가능"
              end
            elsif ts[:house].to_s.strip == '후플푸프' && ts[:passive] == '2' &&
                  !ctx[:guard_used][tname] && target[:hp].to_i - dmg <= 0 && dmg > 0
              dmg = target[:hp].to_i - 1
              ctx[:guard_used][tname] = true
              log << "#{display_name_of.call(tname)}: [후플푸프] 전투 중 1회 — 건강 0 이하 방지"
            end
---NEW---
            if ts[:house].to_s.strip == '후플푸프' && ts[:passive] == '2' &&
               !ctx[:guard_used][tname] && target[:hp].to_i - dmg <= 0 && dmg > 0
              dmg = target[:hp].to_i - 1
              ctx[:guard_used][tname] = true
              log << "#{display_name_of.call(tname)}: [후플푸프] 전투 중 1회 — 건강 0 이하 방지"
            end
===PATCH 10 FILE=battle_round.rb===
---OLD---
  ctx[:prev_took_damage] = took_damage
  battle_actions.each { |name, act| ctx[:prev_action][name] = act[:type] }
  cleanup_buffs!(ctx)
  advance_cooldowns!(ctx)
  ctx[:cover] = {}
  ctx[:revenge] = {}
  ctx[:sure_hit] = {}
  ctx[:survive_once] = {}
---NEW---
  ctx[:indomitable_buffer].to_a.each do |name, total_power|
    next if total_power.to_i <= 0
    guardian = state_of.call(name)
    next unless guardian && guardian[:hp].to_i > 0
    gs = stats_of.call(name)
    eff_dur = (gs[:dur].to_i + dur_bonus[name]) * defended_multiplier[name]
    dmg = BattleCalculator.calc_damage(total_power.to_i, eff_dur.to_i)
    if shields[name].to_i > 0 && dmg > 0
      blocked = [shields[name], dmg].min
      shields[name] -= blocked
      dmg -= blocked
      log << "#{display_name_of.call(name)} 보호막 #{blocked} 흡수"
    end
    if guardian[:hp].to_i - dmg <= 0 && dmg > 0
      dmg = guardian[:hp].to_i - 1
      log << "#{display_name_of.call(name)}: 필사즉생 → 이번 라운드 흡수한 총 위력 #{total_power}, 최종 피해 #{dmg} (건강 0 이하 방지)"
    else
      log << "#{display_name_of.call(name)}: 필사즉생 → 이번 라운드 흡수한 총 위력 #{total_power}, 최종 피해 #{dmg}"
    end
    guardian[:hp] = [guardian[:hp].to_i - dmg, 0].max
    took_damage[name] = true if dmg > 0
    if ctx[:revenge][name] && dmg > 0
      rev_by = ctx[:revenge][name][:by]
      rev_actor = state_of.call(rev_by)
      if rev_actor && rev_actor[:hp].to_i > 0
        rev_dmg = BattleCalculator.calc_damage((dmg * ctx[:revenge][name][:multiplier]).ceil, creature[:dur].to_i)
        creature[:hp] = [creature[:hp].to_i - rev_dmg, 0].max
        log << "#{display_name_of.call(rev_by)}의 복수 → #{creature[:name]}에게 #{rev_dmg} 반격 피해"
      end
    end
    if guardian[:hp].to_i <= 0
      guardian[:status] = '전투불가'
      log << "#{display_name_of.call(name)} 전투불가"
    end
  end

  ctx[:prev_took_damage] = took_damage
  battle_actions.each { |name, act| ctx[:prev_action][name] = act[:type] }
  cleanup_buffs!(ctx)
  advance_cooldowns!(ctx)
  ctx[:cover] = {}
  ctx[:revenge] = {}
  ctx[:sure_hit] = {}
  ctx[:survive_once] = {}
  ctx[:indomitable_buffer] = Hash.new(0)
