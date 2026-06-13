require_relative 'battle_calculator'

class BattleProcessor
  SUPPORT_SKILLS = %w[회복 활력 구원 강화 보호 희생 철벽 주의분산 즉발 백발백중 응원 행운부여].freeze
  ATTACK_SKILLS  = %w[공격 초인적인힘 흙뿌리기 혼란 습격 폭발 고육지책].freeze
  DEFENSE_SKILLS = %w[방어 회피 복수 희생 철벽 주의분산 필사즉생 보호].freeze

  def self.normalize(name)
    name.to_s.strip.gsub(/\s+/, '')
  end

  def initialize(base_stats, current_states, commands, skill_data, corrections, cooldowns, round, team_name)
    @base      = base_stats.each_with_object({}) { |s, h| h[s[:name]] = s }
    @states    = current_states.each_with_object({}) { |s, h| h[s[:name]] = s.dup }
    @cmds      = commands.each_with_object({}) { |c, h| h[c[:name]] = c }
    @skills    = skill_data.each_with_object({}) { |s, h| h[self.class.normalize(s[:name])] = s }
    @corr      = corrections
    @cooldowns = cooldowns
    @round     = round
    @team_name = team_name
    @log       = { support: [], move: [], attack: [], defense: [], result: [] }
    @buffs     = {}
    init_buffs
  end

  def process
    apply_corrections
    process_support
    process_move
    process_attack
    process_defense
    build_result_log
    updated_cooldowns = advance_cooldowns
    [@log, @states, updated_cooldowns]
  end

  private

  def init_buffs
    @states.each_key do |name|
      @buffs[name] = {
        atk_up: 0, dur_up: 0, agi_up: 0, tec_up: 0, luck_up: 0,
        shield: 0, guardian: nil, guaranteed: false,
        indomitable: false, stunned: false, confused: 0,
        blinded: false, revenge_ready: false, defense_stance: false
      }
    end
  end

  def on_cooldown?(name, action)
    @cooldowns.dig(name, action).to_i > 0
  end

  def set_cooldown(name, action)
    skill = @skills[action]
    return unless skill
    cd_str = skill[:cooldown].to_s.strip
    return if cd_str.empty? || cd_str == '0'
    if cd_str.include?('회')
      @cooldowns[name] ||= {}
      @cooldowns[name][action] = 999
      return
    end
    cd = cd_str.to_i
    return if cd <= 0
    @cooldowns[name] ||= {}
    @cooldowns[name][action] = cd
  end

  def advance_cooldowns
    result = {}
    @cooldowns.each do |name, skills|
      skills.each do |skill, left|
        next if left <= 0
        new_left = left == 999 ? 999 : left - 1
        result[name] ||= {}
        result[name][skill] = new_left if new_left > 0
      end
    end
    result
  end

  def apply_corrections
    @corr.each do |c|
      name = c[:name]
      next unless @states.key?(name)
      case c[:type]
      when '체력보정'
        @states[name][:hp] += c[:value].to_i
        @states[name][:hp] = [[@states[name][:hp], 0].max, @base[name]&.dig(:hp) || 999].min
      when '사거리불가'
        @cmds[name]&.merge!(action: '미행동', targets: [])
        @log[:attack] << "#{name}: 사거리 불가 — 행동 무효"
      when '사망'
        @states[name][:hp] = 0
        @log[:result] << "#{name}: 사망 처리"
      when '부활'
        @states[name][:hp] = @base[name]&.dig(:hp) || 50
        @states[name][:pos] = c[:value] unless c[:value].empty?
        @log[:support] << "#{name}: #{c[:value]}에 부활"
      when '쿨타임초기화'
        target_skill = c[:value].to_s.strip
        if target_skill.empty?
          @cooldowns.delete(name)
          @log[:support] << "#{name}: 전체 쿨타임 초기화"
        else
          @cooldowns[name]&.delete(target_skill)
          @log[:support] << "#{name}: [#{target_skill}] 쿨타임 초기화"
        end
      end
    end
  end

  def process_support
    @cmds.each do |name, cmd|
      action = self.class.normalize(cmd[:action].to_s)
      next if action.empty? || action == '미행동'
      next if @states[name][:hp] <= 0
      skill = @skills[action]
      next unless skill && skill[:type] == '지원'
      if on_cooldown?(name, action)
        @log[:support] << "#{name} → [#{action}]: 쿨타임 중 (#{@cooldowns.dig(name, action)}라운드 남음)"
        next
      end
      targets     = cmd[:targets]
      base        = @base[name]
      caster_atk  = (base[:atk]  + @buffs[name][:atk_up]).to_i
      caster_luck = (base[:luck] + @buffs[name][:luck_up]).to_i
      case action
      when '회복'
        t = targets.first || name
        if @states[t]
          is_crit = BattleCalculator.critical?(caster_luck)
          heal    = BattleCalculator.calc_heal('회복', caster_atk, is_critical: is_crit)
          max_hp  = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          @log[:support] << "#{name} → [회복] #{t} 건강 +#{heal}#{crit_str} (현재: #{@states[t][:hp]})"
        end
      when '활력'
        t = targets.first || name
        if @states[t]
          is_crit = BattleCalculator.critical?(caster_luck)
          heal    = BattleCalculator.calc_heal('활력', caster_atk, is_critical: is_crit)
          max_hp  = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          @log[:support] << "#{name} → [활력] #{t} 건강 +#{heal}#{crit_str} (현재: #{@states[t][:hp]})"
        end
      when '구원'
        targets.each do |t|
          next unless @states[t]
          is_crit = BattleCalculator.critical?(caster_luck)
          heal    = BattleCalculator.calc_heal('구원', caster_atk, is_critical: is_crit)
          max_hp  = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          @log[:support] << "#{name} → [구원] #{t} 건강 +#{heal}"
        end
      when '강화'
        bonus = (caster_atk * 0.5).ceil
        valid_targets = targets.select do |t|
          @states[t] && BattleCalculator.in_range?(skill[:range], @states[name][:pos], @states[t][:pos])
        end
        valid_targets.each { |t| @buffs[t][:atk_up] += bonus }
        @log[:support] << "#{name} → [강화] #{valid_targets.join(', ')} 마법능력 +#{bonus}"
      when '보호'
        targets.first(3).each do |t|
          next unless @buffs[t]
          @buffs[t][:shield] += 30
        end
        @log[:support] << "#{name} → [보호] #{targets.first(3).join(', ')}에게 보호막 30"
      when '백발백중'
        t = targets.first
        if t && @buffs[t]
          @buffs[t][:guaranteed] = true
          @log[:support] << "#{name} → [백발백중] #{t} 이번 행동 반드시 성공 + 크리티컬 전환"
        end
      when '응원'
        t = targets.first
        if t && @buffs[t]
          @buffs[t][:luck_up] += 10
          @log[:support] << "#{name} → [응원] #{t} 행운 +10 (2턴)"
        end
      when '즉발'
        t = targets.first
        skill_to_reset = cmd[:target_pos].to_s.strip
        if t && !skill_to_reset.empty?
          @cooldowns[t]&.delete(skill_to_reset)
          @log[:support] << "#{name} → [즉발] #{t}의 [#{skill_to_reset}] 쿨타임 초기화"
        else
          @log[:support] << "#{name} → [즉발] 대상 스킬명 미입력 (무효)"
        end
      when '행운부여'
        t = targets.first
        if @states[t] && !cmd[:target_pos].empty?
          old_pos = @states[t][:pos]
          @states[t][:pos] = cmd[:target_pos]
          @log[:support] << "#{name} → [행운부여] #{t}: #{old_pos} → #{cmd[:target_pos]}"
        end
      end
      set_cooldown(name, action)
    end
  end

  def process_move
    @cmds.each do |name, cmd|
      next if @states[name][:hp] <= 0
      action = self.class.normalize(cmd[:action].to_s)
      next if action == '습격'
      if action == '순간이동'
        t    = cmd[:targets].first
        dest = cmd[:target_pos].to_s.strip
        if t && @states[t] && !dest.empty?
          old_pos = @states[t][:pos]
          @states[t][:pos] = dest
          @log[:move] << "#{name} → [순간이동] #{t}: #{old_pos} → #{dest}"
        end
        next
      end
      to   = cmd[:move_to].to_s.strip
      from = @states[name][:pos].to_s.strip
      next if to.empty? || to == from
      dist = BattleCalculator.move_cost(from, to)
      if dist > 5
        @log[:move] << "#{name}: 이동 불가 — 최대 5칸 (#{from}→#{to}, #{dist}칸)"
        next
      end
      @states[name][:pos] = to
      @log[:move] << "#{name}: #{from} → #{to}"
    end
  end

  def process_attack
    @cmds.each do |name, cmd|
      action = self.class.normalize(cmd[:action].to_s)
      next unless ATTACK_SKILLS.include?(action)
      next if @states[name][:hp] <= 0
      base = @base[name]
      next unless base
      if on_cooldown?(name, action)
        @log[:attack] << "#{name} → [#{action}]: 쿨타임 중 (#{@cooldowns.dig(name, action)}라운드 남음)"
        next
      end
      skill       = @skills[action]
      caster_atk  = (base[:atk]  + @buffs[name][:atk_up]).to_i
      caster_tec  = (base[:tec]  + @buffs[name][:tec_up]).to_i
      caster_luck = (base[:luck] + @buffs[name][:luck_up]).to_i
      caster_pos  = @states[name][:pos]
      caster_facing = base[:facing].to_s.strip
      targets = if action == '폭발'
                  @states.keys.select do |tname|
                    next false if @states[tname][:hp] <= 0
                    next false if same_team?(name, tname)
                    rng = skill ? skill[:range] : '2'
                    BattleCalculator.in_range?(rng, caster_pos, @states[tname][:pos])
                  end
                else
                  cmd[:targets]
                end
      if targets.empty?
        @log[:attack] << "#{name} → [#{action}]: 대상 없음"
        next
      end
      targets.each do |tname|
        next unless @states[tname]
        next if @states[tname][:hp] <= 0
        tgt_state = @states[tname]
        tgt_base  = @base[tname]
        next unless tgt_base
        tgt_pos = tgt_state[:pos]
        unless action == '습격' || action == '고육지책'
          rng = skill ? skill[:range] : '-'
          unless BattleCalculator.in_range?(rng, caster_pos, tgt_pos)
            @log[:attack] << "#{name} → [#{action}] #{tname}: 사거리 밖"
            next
          end
        end
        if action == '흙뿌리기'
          unless BattleCalculator.in_front?(caster_pos, tgt_pos, caster_facing)
            @log[:attack] << "#{name} → [흙뿌리기] #{tname}: 머리방향 전방이 아님 (facing: #{caster_facing})"
            next
          end
        end
        if action == '습격'
          ally_positions = @states.select { |n, s| n != name && s[:hp] > 0 && same_team?(name, n) }
                                  .values.map { |s| s[:pos] }
          if BattleCalculator.path_blocked?(caster_pos, tgt_pos, ally_positions)
            @log[:attack] << "#{name} → [습격] #{tname}: 아군이 경로를 막고 있음"
            next
          end
          old_pos = caster_pos
          @states[name][:pos] = tgt_pos
          @log[:move] << "#{name}: [습격] #{old_pos} → #{tgt_pos}"
          caster_pos = tgt_pos
        end
        if @buffs[tname]&.dig(:stunned)
          @log[:attack] << "#{name} → [#{action}] #{tname}: 행동 불가 상태"
          next
        end
        tgt_agi   = (tgt_base[:agi] + @buffs[tname][:agi_up]).to_i
        guaranteed = @buffs[name][:guaranteed]
        unless guaranteed
          unless BattleCalculator.hit?(caster_tec)
            @log[:attack] << "#{name} → [#{action}] #{tname}: 빗나감"
            next
          end
          if BattleCalculator.evade?(tgt_agi)
            @log[:attack] << "#{name} → [#{action}] #{tname}: 회피"
            next
          end
        end
        is_crit = guaranteed || BattleCalculator.critical?(caster_luck)
        extra_params = {}
        if action == '습격'
          extra_params[:distance] = BattleCalculator.distance(@states[name][:pos], tgt_pos)
        end
        if action == '고육지책'
          sacrifice = cmd[:extra].to_i
          extra_params[:hp_sacrifice] = sacrifice
          @states[name][:hp] -= sacrifice
          @log[:attack] << "#{name}: [고육지책] 자기 건강 -#{sacrifice}"
        end
        raw_dmg = BattleCalculator.calc_skill_damage(
          action, caster_atk, is_critical: is_crit, extra_params: extra_params
        )
        actual_target = tname
        if @buffs[tname][:guardian]
          guardian = @buffs[tname][:guardian]
          if @states[guardian] && @states[guardian][:hp] > 0
            actual_target = guardian
            @log[:attack] << "#{guardian} → [희생] #{tname} 대신 피격"
          end
        end
        tgt_dur_final = ((@base[actual_target]&.dig(:dur) || 0) + @buffs[actual_target][:dur_up]).to_i
        effective_dur = @buffs[actual_target][:defense_stance] ? (tgt_dur_final * 1.5).ceil : tgt_dur_final
        dmg = BattleCalculator.calc_damage(raw_dmg, effective_dur)
        if @buffs[actual_target][:indomitable] && @states[actual_target][:hp] - dmg <= 0
          dmg = @states[actual_target][:hp] - 1
        end
        if @buffs[actual_target][:shield] > 0
          absorbed = [@buffs[actual_target][:shield], dmg].min
          @buffs[actual_target][:shield] -= absorbed
          dmg -= absorbed
        end
        @states[actual_target][:hp] = [@states[actual_target][:hp] - dmg, 0].max
        crit_str = is_crit ? ' (크리티컬!)' : ''
        @log[:attack] << "#{name} → [#{action}] #{tname}: 명중#{crit_str} / 피해 #{dmg} (건강 #{@states[actual_target][:hp]})"
        if action == '혼란'
          @buffs[tname][:confused] = (@buffs[tname][:confused] || 0) + 1
          cnt = @buffs[tname][:confused]
          @log[:attack] << "#{tname}: [혼란] 중첩 #{cnt}/5"
          if cnt >= 5
            @buffs[tname][:stunned] = true
            @log[:attack] << "#{tname}: [혼란] 5중첩 — 행동 불가"
          end
        end
        if action == '흙뿌리기'
          @buffs[tname][:blinded] = true
          @buffs[tname][:atk_up] -= (tgt_base[:atk] * 0.2).ceil
          @log[:attack] << "#{tname}: [시야차단] 마법능력 20% 감소"
        end
        if @buffs[tname][:revenge_ready] && dmg > 0
          revenge_dmg = dmg * 2
          @states[name][:hp] = [@states[name][:hp] - revenge_dmg, 0].max
          @log[:defense] << "#{tname} → [복수] #{name}: 피해 #{revenge_dmg}"
        end
        @log[:result] << "#{actual_target}: 건강 0 — 전투 불능." if @states[actual_target][:hp] <= 0
      end
      set_cooldown(name, action)
    end
  end

  def process_defense
    @cmds.each do |name, cmd|
      action = self.class.normalize(cmd[:action].to_s)
      next unless DEFENSE_SKILLS.include?(action)
      next if @states[name][:hp] <= 0
      if on_cooldown?(name, action)
        @log[:defense] << "#{name} → [#{action}]: 쿨타임 중 (#{@cooldowns.dig(name, action)}라운드 남음)"
        next
      end
      base = @base[name]
      next unless base
      case action
      when '방어'
        t = cmd[:targets].first || name
        if @buffs[t]
          @buffs[t][:defense_stance] = true
          @log[:defense] << "#{name} → [방어] #{t} 방어태세 (내구도 1.5배)"
        end
      when '회피'
        @buffs[name][:agi_up] += 20
        @log[:defense] << "#{name} → [회피] 민첩 +20"
      when '복수'
        @buffs[name][:revenge_ready] = true
        @log[:defense] << "#{name} → [복수] 피격 시 2배 반격 대기"
      when '희생'
        t = cmd[:targets].first
        if t && @states[t]
          @buffs[t][:guardian] = name
          @log[:defense] << "#{name} → [희생] #{t}의 피격 대신 받음"
        end
      when '철벽'
        bonus = (base[:dur].to_i * 0.5).ceil
        cmd[:targets].each do |t|
          next unless @buffs[t]
          @buffs[t][:dur_up] += bonus
        end
        @log[:defense] << "#{name} → [철벽] #{cmd[:targets].join(', ')} 내구도 +#{bonus}"
      when '주의분산'
        cmd[:targets].each do |t|
          next unless @buffs[t]
          @buffs[t][:agi_up] += 15
        end
        @log[:defense] << "#{name} → [주의분산] #{cmd[:targets].join(', ')} 민첩 +15"
      when '필사즉생'
        @buffs[name][:indomitable] = true
        @log[:defense] << "#{name} → [필사즉생] 이번 턴 건강 0 이하 방지"
      end
      set_cooldown(name, action)
    end
  end

  def build_result_log
    @states.each do |name, state|
      shield_str = @buffs[name][:shield] > 0 ? " [보호막 #{@buffs[name][:shield]}]" : ""
      @log[:result] << "#{name}: 건강 #{state[:hp]}#{shield_str}"
    end
  end

  def same_team?(name1, name2)
    @cmds.key?(name1) && @cmds.key?(name2)
  end
end
