require_relative 'battle_calculator'

class BattleProcessor
  STANCE_SKILLS  = %w[반격태세 방어태세 회피]
  SUPPORT_SKILLS = %w[경호 보호 회피지원 방어지원 공격지원 행동지원 대상이동
                      회복 다중회복 불굴의의지 소생술 신의가호 속박의낙인 천사의노래]
  ATTACK_SKILLS  = %w[기본공격 저격 강타 관통 폭격 생사결단]
  SPECIAL_USED_KEY = :special_used

  def initialize(base_stats, current_states, commands, skill_data, corrections, round, turn)
    @base    = base_stats.each_with_object({}) { |s, h| h[s[:name]] = s }
    @states  = current_states.each_with_object({}) { |s, h| h[s[:name]] = s.dup }
    @cmds    = commands.each_with_object({}) { |c, h| h[c[:name]] = c }
    @skills  = skill_data.each_with_object({}) { |s, h| h[s[:name]] = s }
    @corr    = corrections
    @round   = round
    @turn    = turn
    @log     = { support: [], move: [], attack: [], result: [] }
    @buffs   = {}  # name => { atk_up:, def_up:, dodge_up:, guard:, shield:, stuned:, indomitable: }
    init_buffs
  end

  def process
    apply_corrections
    process_support
    process_move
    process_attack
    build_result_log
    [@log, @states]
  end

  private

  def init_buffs
    @states.each_key do |name|
      @buffs[name] = { atk_up: 0, def_up: 0, dodge_up: 0, guard: nil, shield: 0, stunned: false, indomitable: false }
    end
  end

  # 보정 시트 적용
  def apply_corrections
    @corr.each do |c|
      name = c[:name]
      next unless @states.key?(name)
      case c[:type]
      when '이동행동력'
        # 우회 이동으로 실제 소모 행동력 재지정
        diff = c[:value].to_i - BattleCalculator.move_cost(@states[name][:pos], @cmds[name]&.dig(:move_to) || @states[name][:pos])
        @states[name][:ap] -= diff if diff != 0
        @log[:move] << "#{name}: 우회 이동 행동력 보정 (#{c[:value]}칸 소모)"
      when '사거리불가'
        # 해당 캐릭터 행동 무효
        @cmds[name]&.merge!(action: '미행동', targets: [])
        @log[:attack] << "#{name}: 사거리 불가 — 행동 무효 처리"
      when '행동력추가'
        @states[name][:ap] += c[:value].to_i
        @log[:support] << "#{name}: 행동력 +#{c[:value]} 보정"
      when '체력보정'
        @states[name][:hp] += c[:value].to_i
        @states[name][:hp] = [[@states[name][:hp], 0].max, @base[name]&.dig(:hp) || 999].min
      when '사망'
        @states[name][:hp] = 0
        @log[:result] << "#{name}: 사망 처리"
      when '부활'
        @states[name][:hp] = @base[name]&.dig(:hp) || 50
        @states[name][:pos] = c[:value] unless c[:value].empty?
        @states[name][:ap] = 5
        @log[:support] << "#{name}: #{c[:value]}에 부활. 최대 체력으로 복귀."
      end
    end
  end

  # 지원 스킬 정산
  def process_support
    @cmds.each do |name, cmd|
      next if cmd[:action].to_s.empty? || cmd[:action] == '미행동'
      skill = @skills[cmd[:action]]
      next unless skill && skill[:type] == '지원'
      next if @states[name][:hp] <= 0

      targets = cmd[:targets]
      caster_state = @states[name]
      base = @base[name]

      case cmd[:action]
      when '행동지원'
        t = targets.first
        if @states[t]
          @states[t][:ap] += 2
          @log[:support] << "#{name} → [행동지원] #{t}의 행동력 +2"
        end
      when '보호'
        t = targets.first || name
        if @states[t]
          shield_val = (base[:hp] * 0.4).ceil
          @buffs[t][:shield] = shield_val
          @log[:support] << "#{name} → [보호] #{t}에게 보호막 #{shield_val} 부여"
        end
      when '경호'
        t = targets.first
        if @states[t]
          @buffs[name][:guard] = t
          @log[:support] << "#{name} → [경호] #{t}의 피격을 대신 받음"
        end
      when '공격지원'
        targets.each do |t|
          next unless @states[t]
          @buffs[t][:atk_up] += 15
        end
        @log[:support] << "#{name} → [공격지원] #{targets.join(', ')}의 공격력 +15"
      when '방어지원'
        targets.each do |t|
          next unless @states[t]
          @buffs[t][:def_up] += 15
        end
        @log[:support] << "#{name} → [방어지원] #{targets.join(', ')}의 방어력 +15"
      when '회피지원'
        targets.each do |t|
          next unless @states[t]
          @buffs[t][:dodge_up] += 20
        end
        @log[:support] << "#{name} → [회피지원] #{targets.join(', ')}의 회피율 +20"
      when '회복'
        t = targets.first || name
        if @states[t]
          heal = (base[:hp] * 0.4).ceil
          max_hp = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          @log[:support] << "#{name} → [회복] #{t} 체력 +#{heal} (현재: #{@states[t][:hp]})"
        end
      when '다중회복'
        targets.each do |t|
          next unless @states[t]
          heal = (base[:hp] * 0.3).ceil
          max_hp = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          @log[:support] << "#{name} → [다중회복] #{t} 체력 +#{heal}"
        end
      when '불굴의의지', '불굴의 의지'
        targets.each do |t|
          next unless @states[t]
          @buffs[t][:guard] = name
          @buffs[t][:indomitable] = true
        end
        @log[:support] << "#{name} → [불굴의 의지] #{targets.join(', ')} 보호. 다음 턴 체력 1 이하 방지"
      when '신의가호', '신의 가호'
        targets.each do |t|
          next unless @states[t]
          bonus = (base[:def] * 0.5).ceil
          @buffs[t][:def_up] += bonus
        end
        self_bonus = (base[:def] * 0.5).ceil
        @buffs[name][:def_up] += self_bonus
        @log[:support] << "#{name} → [신의 가호] 아군 방어력 +#{self_bonus}"
      when '속박의낙인', '속박의 낙인'
        targets.each do |t|
          next unless @states[t]
          @buffs[t][:stunned] = true
        end
        @log[:support] << "#{name} → [속박의 낙인] #{targets.join(', ')} 다음 턴 행동 불가"
      when '소생술'
        t = targets.first
        if @states[t] && @states[t][:hp] <= 0
          @states[t][:hp] = @base[t]&.dig(:hp) || 50
          @states[t][:pos] = cmd[:target_pos] unless cmd[:target_pos].empty?
          @states[t][:ap] = 5
          @log[:support] << "#{name} → [소생술] #{t} 즉시 부활"
        end
      when '천사의노래', '천사의 노래'
        targets.each do |t|
          next unless @states[t]
          max_hp = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = max_hp
          @log[:support] << "#{name} → [천사의 노래] #{t} 최대 체력으로 회복"
        end
      when '대상이동'
        t = targets.first
        if @states[t] && !cmd[:target_pos].empty?
          old_pos = @states[t][:pos]
          @states[t][:pos] = cmd[:target_pos]
          @log[:support] << "#{name} → [대상이동] #{t}: #{old_pos} → #{cmd[:target_pos]}"
        end
      end

      # 행동력 차감
      skill_cost = @skills[cmd[:action]]&.dig(:cost) || 0
      caster_state[:ap] -= skill_cost
    end
  end

  # 이동 정산
  def process_move
    @cmds.each do |name, cmd|
      next if @states[name][:hp] <= 0
      to = cmd[:move_to].to_s.strip
      from = @states[name][:pos].to_s.strip
      next if to.empty? || to == from

      cost = BattleCalculator.move_cost(from, to)
      @states[name][:ap] -= cost
      @states[name][:pos] = to
      @log[:move] << "#{name}: #{from} → #{to} (행동력 -#{cost})"
    end
  end

  # 공격 정산
  def process_attack
    # 대기 스킬 먼저 집계 (반격태세, 방어태세, 회피)
    standbys = {}
    @cmds.each do |name, cmd|
      next if @states[name][:hp] <= 0
      action = cmd[:action].to_s
      standbys[name] = action if STANCE_SKILLS.include?(action)
    end

    # 공격 처리
    @cmds.each do |name, cmd|
      action = cmd[:action].to_s
      next unless ATTACK_SKILLS.include?(action)
      next if @states[name][:hp] <= 0

      base_atk = (@base[name][:atk] + @buffs[name][:atk_up]).to_i
      caster_spd = @base[name][:spd].to_i
      caster_tec = @base[name][:tec].to_i

      raw_damage = BattleCalculator.calc_skill_damage(action, base_atk)
      extra      = BattleCalculator.roll_extra(caster_spd, caster_tec)
      ignore_def = (action == '관통')

      targets = cmd[:targets]

      # 폭격: 대상 최대 3명
      targets = targets.first(3) if action == '폭격'

      targets.each do |tname|
        next unless @states[tname]

        # 속박 확인
        if @buffs[tname]&.dig(:stunned)
          @log[:attack] << "#{name} → [#{action}] #{tname}: 속박 상태 — 공격 불가"
          next
        end

        # 경호자 확인
        actual_target = tname
        if @buffs[tname]&.dig(:guard)
          guard_name = @buffs[tname][:guard]
          actual_target = guard_name if @states[guard_name] && @states[guard_name][:hp] > 0
        end

        tgt_state = @states[actual_target]
        tgt_base  = @base[actual_target]
        next unless tgt_state && tgt_base

        tgt_def    = (tgt_base[:def] + @buffs[actual_target][:def_up]).to_i
        tgt_spd    = tgt_base[:spd].to_i
        dodge_bonus = @buffs[actual_target][:dodge_up].to_i

        # 회피 스킬 적용
        dodge_bonus += 50 if standbys[actual_target] == '회피'

        # 저격은 반격 불가
        skip_counter = (action == '저격')

        # 명중 판정
        unless BattleCalculator.hit?(caster_tec, tgt_spd, dodge_bonus)
          @log[:attack] << "#{name} → [#{action}] #{actual_target != tname ? "#{tname}(→경호:#{actual_target})" : tname}: 회피"
          next
        end

        # 방어태세 적용
        dmg_multiplier = standbys[actual_target] == '방어태세' ? 0.8 : 1.0

        dmg = BattleCalculator.calc_damage(raw_damage, ignore_def ? 0 : tgt_def, extra, ignore_def: ignore_def)
        dmg = (dmg * dmg_multiplier).ceil

        # 불굴: 체력 1 이하 방지
        if @buffs[actual_target][:indomitable] && tgt_state[:hp] - dmg <= 0
          dmg = tgt_state[:hp] - 1
          dmg = 0 if dmg < 0
        end

        # 보호막 처리
        new_hp, new_shield = BattleCalculator.apply_shield(tgt_state[:hp], @buffs[actual_target][:shield], dmg)
        @buffs[actual_target][:shield] = new_shield
        tgt_state[:hp] = new_hp

        tname_str = actual_target != tname ? "#{tname}(→경호:#{actual_target})" : tname
        @log[:attack] << "#{name} → [#{action}] #{tname_str}: 명중 / 피해 #{dmg} (체력 #{new_hp})"

        # 생사결단 반동
        if action == '생사결단'
          recoil = (raw_damage * 0.3).ceil
          @states[name][:hp] = [@states[name][:hp] - recoil, 0].max
          @log[:attack] << "#{name}: 반동 피해 #{recoil} (체력 #{@states[name][:hp]})"
        end

        # 반격 처리 (저격 제외, 반격태세인 경우)
        unless skip_counter
          if standbys[actual_target] == '반격태세' && tgt_state[:hp] > 0
            c_atk  = @base[actual_target][:atk].to_i
            c_spd  = tgt_base[:spd].to_i
            c_tec  = tgt_base[:tec].to_i
            c_extra = BattleCalculator.roll_extra(c_spd, c_tec)
            c_def  = @base[name][:def].to_i

            if BattleCalculator.hit?(c_tec, @base[name][:spd].to_i)
              c_dmg = BattleCalculator.calc_damage(c_atk, c_def, c_extra)
              @states[name][:hp] = [@states[name][:hp] - c_dmg, 0].max
              @log[:attack] << "#{actual_target} → [반격] #{name}: 피해 #{c_dmg} (체력 #{@states[name][:hp]})"
            else
              @log[:attack] << "#{actual_target} → [반격] #{name}: 회피"
            end
          end
        end

        # 사망 처리
        if tgt_state[:hp] <= 0
          @log[:result] << "#{actual_target}: 체력 0 — 사망. 다음 턴 복귀 예정."
        end
      end

      # 행동력 차감
      skill_cost = @skills[action]&.dig(:cost) || 1
      @states[name][:ap] -= skill_cost
    end
  end

  # 최종 현황 로그 생성
  def build_result_log
    @states.each do |name, state|
      shield_str = @buffs[name][:shield] > 0 ? " [보호막 #{@buffs[name][:shield]}]" : ""
      @log[:result] << "#{name}: 체력 #{state[:hp]} / 행동력 #{state[:ap]}#{shield_str}"
    end
  end
end
