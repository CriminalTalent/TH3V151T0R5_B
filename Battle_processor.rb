require_relative 'battle_calculator'

class BattleProcessor
  MOVE_SKILLS    = %w[이동 습격 순간이동]
  SUPPORT_SKILLS = %w[회복 활력 구원 강화 보호 희생 철벽 주의분산 즉발 백발백중 응원 행운부여]
  ATTACK_SKILLS  = %w[공격 초인적인힘 흙뿌리기 혼란 습격 폭발 고육지책]
  DEFENSE_SKILLS = %w[방어 회피 복수 희생 철벽 주의분산 필사즉생 보호]

  # 스킬명 정규화 (공백 제거)
  def self.normalize(name)
    name.to_s.strip.gsub(/\s+/, '')
  end

  def initialize(base_stats, current_states, commands, skill_data, corrections, round, turn)
    @base   = base_stats.each_with_object({}) { |s, h| h[s[:name]] = s }
    @states = current_states.each_with_object({}) { |s, h| h[s[:name]] = s.dup }
    @cmds   = commands.each_with_object({}) { |c, h| h[c[:name]] = c }
    @skills = skill_data.each_with_object({}) { |s, h| h[self.class.normalize(s[:name])] = s }
    @corr   = corrections
    @round  = round
    @turn   = turn
    @log    = { support: [], move: [], attack: [], defense: [], result: [] }
    @buffs  = {}
    init_buffs
  end

  def process
    apply_corrections
    process_support
    process_move
    process_attack
    process_defense
    build_result_log
    [@log, @states]
  end

  private

  def init_buffs
    @states.each_key do |name|
      @buffs[name] = {
        atk_up: 0, dur_up: 0, agi_up: 0, tec_up: 0, luck_up: 0,
        shield: 0, guardian: nil, guaranteed: false,
        indomitable: false, stunned: false, confused: 0,
        blinded: false, revenge: false
      }
    end
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
        @log[:support] << "#{name}: 쿨타임 초기화 (수동)"
      end
    end
  end

  def process_support
    @cmds.each do |name, cmd|
      action_raw = cmd[:action].to_s.strip
      action = self.class.normalize(action_raw)
      next if action.empty? || action == '미행동'
      next if @states[name][:hp] <= 0

      skill = @skills[action]
      next unless skill && skill[:type] == '지원'

      targets = cmd[:targets]
      base = @base[name]
      caster_atk = (base[:atk] + @buffs[name][:atk_up]).to_i

      case action
      when '회복'
        t = targets.first || name
        if @states[t]
          is_crit = BattleCalculator.critical?(base[:luck].to_i + @buffs[name][:luck_up].to_i)
          heal = BattleCalculator.calc_heal('회복', caster_atk, is_critical: is_crit)
          max_hp = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          @log[:support] << "#{name} → [회복] #{t} 건강 +#{heal}#{crit_str} (현재: #{@states[t][:hp]})"
        end
      when '활력'
        t = targets.first || name
        if @states[t]
          is_crit = BattleCalculator.critical?(base[:luck].to_i + @buffs[name][:luck_up].to_i)
          heal = BattleCalculator.calc_heal('활력', caster_atk, is_critical: is_crit)
          max_hp = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          @log[:support] << "#{name} → [활력] #{t} 건강 +#{heal}#{crit_str} (현재: #{@states[t][:hp]})"
        end
      when '구원'
        targets.each do |t|
          next unless @states[t]
          is_crit = BattleCalculator.critical?(base[:luck].to_i + @buffs[name][:luck_up].to_i)
          heal = BattleCalculator.calc_heal('구원', caster_atk, is_critical: is_crit)
          max_hp = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          @log[:support] << "#{name} → [구원] #{t} 건강 +#{heal}"
        end
      when '강화'
        bonus = (caster_atk * 0.5).ceil
        targets.each do |t|
          next unless @buffs[t]
          @buffs[t][:atk_up] += bonus
        end
        @log[:support] << "#{name} → [강화] #{targets.join(', ')} 마법능력 +#{bonus}"
      when '보호'
        targets.first(3).each do |t|
          next unless @buffs[t]
          @buffs[t][:shield] += 30
        end
        @log[:support] << "#{name} → [보호] #{targets.first(3).join(', ')}에게 보호막 30"
      when '백발백중'
        t = targets.first
        if @buffs[t]
          @buffs[t][:guaranteed] = true
          @log[:support] << "#{name} → [백발백중] #{t} 이번 행동 반드시 성공 + 크리티컬 전환"
        end
      when '응원'
        t = targets.first
        if @buffs[t]
          @buffs[t][:luck_up] += 10
          @log[:support] << "#{name} → [응원] #{t} 행운 +10 (2턴)"
        end
      when '즉발'
        t = targets.first
        @log[:support] << "\#{name} → [즉발] \#{t}의 기술 쿨타임 0으로 (수동 확인 필요)"
      when '행운부여'
        t = targets.first
        if @states[t] && !cmd[:target_pos].empty?
          old_pos = @states[t][:pos]
          @states[t][:pos] = cmd[:target_pos]
          @log[:support] << "\#{name} → [행운부여] \#{t}: \#{old_pos} → \#{cmd[:target_pos]}"
        end
      end
    end
  end

  def process_move
    @cmds.each do |name, cmd|
      next if @states[name][:hp] <= 0
      action = self.class.normalize(cmd[:action].to_s)
      next if action == '습격'  # 습격은 공격에서 처리

      # 순간이동: 대상을 사거리 내 마스로 이동
      if action == '순간이동'
        t = cmd[:targets].first
        dest = cmd[:target_pos].to_s.strip
        if @states[t] && !dest.empty?
          old_pos = @states[t][:pos]
          @states[t][:pos] = dest
          @log[:move] << "#{name} → [순간이동] #{t}: #{old_pos} → #{dest}"
        end
        next
      end

      to = cmd[:move_to].to_s.strip
      from = @states[name][:pos].to_s.strip
      next if to.empty? || to == from

      dist = BattleCalculator.move_cost(from, to)
      if dist > 1
        @log[:move] << "#{name}: 이동 불가 — 최대 1칸 (#{from}→#{to} #{dist}칸)"
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
      caster_atk = (base[:atk] + @buffs[name][:atk_up]).to_i
      caster_tec = (base[:tec] + @buffs[name][:tec_up]).to_i
      caster_luck = (base[:luck] + @buffs[name][:luck_up]).to_i

      targets = cmd[:targets]

      targets.each do |tname|
        next unless @states[tname]
        next if @states[tname][:hp] <= 0

        tgt_state = @states[tname]
        tgt_base  = @base[tname]
        next unless tgt_base

        tgt_dur   = (tgt_base[:dur] + @buffs[tname][:dur_up]).to_i
        tgt_agi   = (tgt_base[:agi] + @buffs[tname][:agi_up]).to_i

        # 속박 확인
        if @buffs[tname]&.dig(:stunned)
          @log[:attack] << "#{name} → [#{action}] #{tname}: 속박 상태"
          next
        end

        # 명중 판정 (백발백중이면 스킵)
        guaranteed = @buffs[name][:guaranteed]
        unless guaranteed
          unless BattleCalculator.hit?(caster_tec, 0)
            @log[:attack] << "#{name} → [#{action}] #{tname}: 빗나감"
            next
          end
          # 회피 판정
          if BattleCalculator.evade?(tgt_agi)
            @log[:attack] << "#{name} → [#{action}] #{tname}: 회피"
            next
          end
        end

        # 크리티컬 판정
        is_crit = guaranteed || BattleCalculator.critical?(caster_luck)

        # 습격: 거리 계산
        extra_params = {}
        if action == '습격'
          from = @states[name][:pos]
          extra_params[:distance] = BattleCalculator.distance(from, tgt_state[:pos])
        end

        # 고육지책: HP 차감량
        if action == '고육지책'
          sacrifice = cmd[:extra].to_i
          extra_params[:hp_sacrifice] = sacrifice
          @states[name][:hp] -= sacrifice
        end

        raw_dmg = BattleCalculator.calc_skill_damage(
          action.gsub(/([가-힣])/, ' \1').strip,
          caster_atk,
          is_critical: is_crit,
          extra_params: extra_params
        )

        # 방어태세 적용 (1.5배 내구도)
        effective_dur = tgt_dur
        if @buffs[tname][:defense_stance]
          effective_dur = (tgt_dur * 1.5).ceil
        end

        dmg = BattleCalculator.calc_damage(raw_dmg, effective_dur)

        # 불굴 처리
        if @buffs[tname][:indomitable] && tgt_state[:hp] - dmg <= 0
          dmg = tgt_state[:hp] - 1
        end

        # 보호막 처리
        if @buffs[tname][:shield] > 0
          absorbed = [@buffs[tname][:shield], dmg].min
          @buffs[tname][:shield] -= absorbed
          dmg -= absorbed
        end

        tgt_state[:hp] = [tgt_state[:hp] - dmg, 0].max

        crit_str = is_crit ? ' (크리티컬!)' : ''
        @log[:attack] << "#{name} → [#{action}] #{tname}: 명중#{crit_str} / 피해 #{dmg} (건강 #{tgt_state[:hp]})"

        # 상태이상 부여
        if action == '혼란'
          @buffs[tname][:confused] = (@buffs[tname][:confused] || 0) + 1
          confused_count = @buffs[tname][:confused]
          @log[:attack] << "#{tname}: [혼란] 중첩 #{confused_count}/5"
          if confused_count >= 5
            @buffs[tname][:stunned] = true
            @log[:attack] << "#{tname}: [혼란] 5중첩 — 해당 턴 행동 불가"
          end
        end

        if action == '흙뿌리기'
          @buffs[tname][:blinded] = true
          @buffs[tname][:atk_up] -= (tgt_base[:atk] * 0.2).ceil
          @log[:attack] << "#{tname}: [시야차단] 마법능력 20% 감소"
        end

        # 복수 대기 등록
        if @buffs[tname][:revenge_ready] && dmg > 0
          revenge_dmg = dmg * 2
          @states[name][:hp] = [@states[name][:hp] - revenge_dmg, 0].max
          @log[:defense] << "#{tname} → [복수] #{name}: 피해 #{revenge_dmg}"
        end

        # 사망
        if tgt_state[:hp] <= 0
          @log[:result] << "#{tname}: 건강 0 — 전투 불능."
        end
      end
    end
  end

  def process_defense
    @cmds.each do |name, cmd|
      action = self.class.normalize(cmd[:action].to_s)
      next unless DEFENSE_SKILLS.include?(action)
      next if @states[name][:hp] <= 0

      base = @base[name]

      case action
      when '방어'
        t = cmd[:targets].first || name
        if @buffs[t]
          @buffs[t][:dur_up] += (@base[t]&.dig(:dur).to_i * 0.5).ceil
          @log[:defense] << "#{name} → [방어] #{t} 내구도 1.5배"
        end
      when '회피'
        @buffs[name][:agi_up] += 20
        @log[:defense] << "#{name} → [회피] 민첩 +20"
      when '복수'
        @buffs[name][:revenge_ready] = true
        @log[:defense] << "#{name} → [복수] 피격 시 2배 반격 대기"
      when '희생'
        t = cmd[:targets].first
        if @states[t]
          @buffs[t][:guardian] = name
          @log[:defense] << "#{name} → [희생] #{t}의 피격 대신 받음"
        end
      when '철벽'
        bonus = (base[:dur].to_i * 0.5).ceil
        cmd[:targets].each do |t|
          next unless @buffs[t]
          @buffs[t][:dur_up] += bonus
        end
        @log[:defense] << "#{name} → [철벽] 사거리 내 전원 내구도 +#{bonus}"
      when '주의분산'
        cmd[:targets].each do |t|
          next unless @buffs[t]
          @buffs[t][:agi_up] += 15
        end
        @log[:defense] << "#{name} → [주의분산] 사거리 내 전원 민첩 +15"
      when '필사즉생'
        @buffs[name][:indomitable] = true
        @log[:defense] << "#{name} → [필사즉생] 이번 턴 건강 0 이하 방지"
      end
    end
  end

  def build_result_log
    @states.each do |name, state|
      shield_str = @buffs[name][:shield] > 0 ? " [보호막 #{@buffs[name][:shield]}]" : ""
      @log[:result] << "#{name}: 건강 #{state[:hp]}#{shield_str}"
    end
  end
end
