require_relative 'battle_calculator'

class BattleProcessor
  SUPPORT_SKILLS = %w[회복 활력 구원 강화 보호 희생 철벽 주의분산 즉발 백발백중 응원 행운부여].freeze
  ATTACK_SKILLS  = %w[공격 초인적인힘 흙뿌리기 혼란 습격 폭발 고육지책].freeze
  DEFENSE_SKILLS = %w[방어 회피 복수 희생 철벽 주의분산 필사즉생 보호].freeze

  def self.normalize(name)
    name.to_s.strip.gsub(/\s+/, '')
  end

  # cooldowns: { "캐릭터명" => { "스킬명" => 남은라운드 } }
  # buffs_in:  { "캐릭터명" => [ { type:, value:, left: } ] }
  def initialize(base_stats, current_states, commands, skill_data, corrections, cooldowns, buffs_in, round, team_name)
    @base      = base_stats.each_with_object({}) { |s, h| h[s[:name]] = s }
    @states    = current_states.each_with_object({}) { |s, h| h[s[:name]] = s.dup }
    @cmds      = commands.each_with_object({}) { |c, h| h[c[:name]] = c }
    @skills    = skill_data.each_with_object({}) { |s, h| h[self.class.normalize(s[:name])] = s }
    @corr      = corrections
    @cooldowns = cooldowns
    @buffs_in  = buffs_in
    @round     = round
    @team_name = team_name
    @log       = { support: [], move: [], attack: [], defense: [], result: [] }
    @buffs     = {}
    @passive_log = []
    init_buffs
    apply_house_passives_pre
  end

  def process
    log_unrecognized_or_cooldown_actions
    apply_corrections
    process_support
    process_move
    process_attack
    process_defense
    apply_house_passives_post
    build_result_log
    updated_cooldowns = advance_cooldowns
    updated_buffs     = advance_buffs
    [@log, @states, updated_cooldowns, updated_buffs]
  end

  private

  # ─── 미분류/쿨타임 행동 사전 로그 ─────────────────────────────────
  # 입력된 행동이 스킬 시트에 없거나, 쿨타임 중이면 결과 툿에 명시
  def log_unrecognized_or_cooldown_actions
    @cmds.each do |name, cmd|
      next unless @states[name]
      next if @states[name][:hp] <= 0

      raw_action = cmd[:action].to_s.strip
      action = self.class.normalize(raw_action)

      if action.empty? || action == '미행동' || action == '이동'
        next
      end

      skill = @skills[action]

      if skill.nil?
        @log[:attack] << "#{name} → [#{raw_action}]: 등록되지 않은 행동명 (스킬 시트 확인 필요)"
        next
      end

      category = case skill[:type]
                 when '공격' then :attack
                 when '방어' then :defense
                 when '지원' then :support
                 else :attack
                 end

      if on_cooldown?(name, action)
        left = @cooldowns.dig(name, action)
        left_str = left == 999 ? '전투 종료까지' : "#{left}라운드"
        @log[category] << "#{name} → [#{action}]: 쿨타임 중 (#{left_str} 남음) — 행동 무효"
      end
    end
  end

  # ─── 초기화 ─────────────────────────────────────────────────────

  def init_buffs
    @states.each_key do |name|
      @buffs[name] = {
        atk_up: 0, dur_up: 0, agi_up: 0, tec_up: 0, luck_up: 0,
        shield: 0, guardian: nil, guaranteed: false,
        indomitable: false, stunned: false, confused: 0,
        blinded: false, revenge_ready: false, defense_stance: false,
        no_action_last_round: false, took_damage_last_round: false
      }
    end

    # 버프탭에서 지속 버프 복원
    @buffs_in.each do |name, list|
      next unless @buffs[name]
      list.each do |b|
        case b[:type]
        when '혼란중첩'
          @buffs[name][:confused] = b[:value].to_i
        when '행운증가'
          @buffs[name][:luck_up] += b[:value].to_i if b[:left] > 0
        when '슬리데린행운'
          @buffs[name][:luck_up] += b[:value].to_i if b[:left] > 0
        when '무행동기록'
          @buffs[name][:no_action_last_round] = (b[:value] == '1')
        when '피격기록'
          @buffs[name][:took_damage_last_round] = (b[:value] == '1')
        end
      end
    end
  end

  # ─── 쿨타임 관리 ─────────────────────────────────────────────────

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

  # ─── 버프(지속효과) 관리 ─────────────────────────────────────────
  # 라운드 종료 시 버프탭에 기록할 내용을 만든다.
  def advance_buffs
    result = {}

    @states.each_key do |name|
      list = []

      # 혼란 중첩은 영구 유지 (행동불가 처리 후에도 기록은 남김)
      if @buffs[name][:confused] > 0
        list << { type: '혼란중첩', value: @buffs[name][:confused], left: 999 }
      end

      # 응원으로 받은 행운 증가 (2턴 지속) — 새로 부여된 경우만 버프탭에 새로 기록
      if @buffs[name][:new_luck_buff] && @buffs[name][:new_luck_buff] > 0
        list << { type: '행운증가', value: @buffs[name][:new_luck_buff], left: 2 }
      end

      # 기존 행운증가 버프 지속시간 차감 후 유지
      @buffs_in[name]&.each do |b|
        next unless b[:type] == '행운증가'
        new_left = b[:left] - 1
        list << { type: '행운증가', value: b[:value], left: new_left } if new_left > 0
      end

      # 슬리데린: 1회 행동 포기 → 다음 라운드부터 전투 종료까지 행운 +10 (영구)
      @buffs_in[name]&.each do |b|
        next unless b[:type] == '슬리데린행운'
        list << { type: '슬리데린행운', value: b[:value], left: 999 }
      end
      if @buffs[name][:new_slytherin_luck]
        list << { type: '슬리데린행운', value: 10, left: 999 }
      end

      # 이번 라운드 무행동 여부 기록 (다음 라운드 그리핀도르/래번클로/슬리데린 판정용)
      no_action = self.class.normalize(@cmds[name]&.dig(:action).to_s).empty? ||
                  self.class.normalize(@cmds[name]&.dig(:action).to_s) == '미행동'
      list << { type: '무행동기록', value: (no_action ? '1' : '0'), left: 999 }

      # 이번 라운드 피격 여부 기록 (후플푸프용)
      took_damage = @buffs[name][:took_damage_this_round] ? '1' : '0'
      list << { type: '피격기록', value: took_damage, left: 999 }

      result[name] = list if list.any?
    end

    result
  end

  # ─── 기숙사 패시브: 라운드 시작 시 적용 (방어/공격 보정) ────────────
  def apply_house_passives_pre
    @states.each_key do |name|
      base = @base[name]
      next unless base
      house   = base[:house]
      passive = base[:passive].to_s.strip

      case house
      when '그리핀도르'
        if passive == '2'
          # 2번: 현재 건강이 최대 건강의 50% 미만이면 마법능력 +50%
          max_hp = base[:hp]
          if max_hp > 0 && @states[name][:hp].to_f < max_hp * 0.5
            bonus = (base[:atk] * 0.5).ceil
            @buffs[name][:atk_up] += bonus
            @passive_log << "#{name}: [그리핀도르] 건강 50% 미만 — 마법능력 +#{bonus}"
          end
        end
        # 1번(맞서는 용기)은 피격 시점에 거리 체크 필요 → process_attack에서 처리

      when '슬리데린'
        if passive == '1'
          # 1번: 이전 라운드 건강 소모 없었으면 이번 라운드 마법능력 +50%
          took_damage = @buffs_in[name]&.any? { |b| b[:type] == '피격기록' && b[:value] == '1' }
          if @round > 1 && took_damage == false
            bonus = (base[:atk] * 0.5).ceil
            @buffs[name][:atk_up] += bonus
            @passive_log << "#{name}: [슬리데린] 이전 라운드 무피해 — 마법능력 +#{bonus}"
          end
        end
        # 2번은 advance_buffs/무행동기록에서 처리 (이미 슬리데린행운으로 반영됨)

      when '래번클로'
        if passive == '1'
          # 1번: 적이 상태이상을 가지고 있으면 마법능력 +50%
          enemy_has_status = @states.keys.any? do |ename|
            next false if same_team?(name, ename)
            @buffs[ename][:confused].to_i > 0 || @buffs[ename][:blinded] || @buffs[ename][:stunned]
          end
          if enemy_has_status
            bonus = (base[:atk] * 0.5).ceil
            @buffs[name][:atk_up] += bonus
            @passive_log << "#{name}: [래번클로] 적 상태이상 감지 — 마법능력 +#{bonus}"
          end
        elsif passive == '2'
          # 2번: 이전 라운드와 다른 분류 행동을 하면 기술 +10
          prev_no_action = @buffs_in[name]&.find { |b| b[:type] == '무행동기록' }
          # 분류 비교는 행동 분류(지원/공격/방어)를 저장해야 하나, 현재는
          # 직전 라운드 행동명을 별도 저장하지 않으므로 무행동기록의 반대 상황만 체크.
          # 간단화: 이전 라운드에 행동했고 이번 라운드도 행동한다면 +10 적용 (분류 추적은 추가 버프키 필요)
          # → '행동분류기록'을 buffs_in에서 찾아 비교
          prev_category = @buffs_in[name]&.find { |b| b[:type] == '행동분류' }&.dig(:value)
          this_action   = self.class.normalize(@cmds[name]&.dig(:action).to_s)
          this_skill    = @skills[this_action]
          this_category = this_skill ? this_skill[:type] : nil
          if prev_category && this_category && prev_category != this_category
            @buffs[name][:tec_up] += 10
            @passive_log << "#{name}: [래번클로] 행동 분류 변경 — 기술 +10"
          end
        end

      when '후플푸프'
        if passive == '1'
          # 1번: 이전 라운드 건강 소모되었으면 이번 라운드 내구도 +50%
          took_damage = @buffs_in[name]&.any? { |b| b[:type] == '피격기록' && b[:value] == '1' }
          if took_damage
            bonus = (base[:dur] * 0.5).ceil
            @buffs[name][:dur_up] += bonus
            @passive_log << "#{name}: [후플푸프] 이전 라운드 피격 — 내구도 +#{bonus}"
          end
        elsif passive == '2'
          # 2번: 전투 중 1회, 체력 0 이하로 떨어지지 않음 (필사즉생과 유사하지만 자동)
          used = @buffs_in[name]&.any? { |b| b[:type] == '후플푸프사용' }
          unless used
            @buffs[name][:hufflepuff_guard] = true
          end
        end
      end
    end

    unless @passive_log.empty?
      @log[:support] << "[기숙사 패시브]"
      @passive_log.each { |l| @log[:support] << l }
    end
  end

  # ─── 기숙사 패시브: 라운드 종료 후 후처리 ────────────────────────
  def apply_house_passives_post
    @states.each_key do |name|
      base = @base[name]
      next unless base
      if base[:house] == '후플푸프' && base[:passive].to_s.strip == '2' && @buffs[name][:hufflepuff_guard] && @buffs[name][:used_hufflepuff_guard]
        # 사용 기록을 버프탭에 영구 저장하기 위해 표시
        @buffs_in[name] ||= []
        @buffs_in[name] << { type: '후플푸프사용', value: '1', left: 999 }
      end

      # 행동 분류 기록 (래번클로 2번용)
      action = self.class.normalize(@cmds[name]&.dig(:action).to_s)
      skill  = @skills[action]
      if skill
        @buffs_in[name] ||= []
        @buffs_in[name] << { type: '행동분류', value: skill[:type], left: 999 }
      end
    end
  end

  def same_team?(name1, name2)
    @cmds.key?(name1) && @cmds.key?(name2)
  end

  # ─── 보정 적용 ───────────────────────────────────────────────────
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
      when '보스반격'
        dmg = c[:value].to_i
        next if dmg <= 0

        candidates = @states.select do |target_name, state|
          state[:hp].to_i > 0 && !same_team?(name, target_name)
        end.keys

        count = candidates.empty? ? 0 : rand(0..candidates.size)
        targets = candidates.sample(count)

        if targets.empty?
          @log[:attack] << "#{name} → [보스반격]: 대상 없음"
        else
          targets.each do |target_name|
            @states[target_name][:hp] = [@states[target_name][:hp] - dmg, 0].max
            @buffs[target_name][:took_damage_this_round] = true if @buffs[target_name]
            @log[:attack] << "#{name} → [보스반격] #{target_name}: 피해 #{dmg} (건강 #{@states[target_name][:hp]})"
          end
        end

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

  # ─── 지원 처리 ───────────────────────────────────────────────────
  def process_support
    @cmds.each do |name, cmd|
      next unless @states[name]
      action = self.class.normalize(cmd[:action].to_s)
      next if action.empty? || action == '미행동'
      next if @states[name][:hp] <= 0

      skill = @skills[action]
      next unless skill && skill[:type] == '지원'

      if on_cooldown?(name, action)
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
          crit_detail = BattleCalculator.critical_detail(caster_luck)
          is_crit = crit_detail[:success]
          heal    = BattleCalculator.calc_heal('회복', caster_atk, is_critical: is_crit)
          max_hp  = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          roll_info = " [#{BattleCalculator.roll_text('크리티컬률', crit_detail)}]"
          @log[:support] << "#{name} → [회복] #{t} 건강 +#{heal}#{crit_str}#{roll_info} (현재: #{@states[t][:hp]})"
        end
      when '활력'
        t = targets.first || name
        if @states[t]
          crit_detail = BattleCalculator.critical_detail(caster_luck)
          is_crit = crit_detail[:success]
          heal    = BattleCalculator.calc_heal('활력', caster_atk, is_critical: is_crit)
          max_hp  = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          roll_info = " [#{BattleCalculator.roll_text('크리티컬률', crit_detail)}]"
          @log[:support] << "#{name} → [활력] #{t} 건강 +#{heal}#{crit_str}#{roll_info} (현재: #{@states[t][:hp]})"
        end
      when '구원'
        targets.each do |t|
          next unless @states[t]
          crit_detail = BattleCalculator.critical_detail(caster_luck)
          is_crit = crit_detail[:success]
          heal    = BattleCalculator.calc_heal('구원', caster_atk, is_critical: is_crit)
          max_hp  = @base[t]&.dig(:hp) || @states[t][:hp]
          @states[t][:hp] = [@states[t][:hp] + heal, max_hp].min
          crit_str = is_crit ? ' (크리티컬!)' : ''
          roll_info = " [#{BattleCalculator.roll_text('크리티컬률', crit_detail)}]"
          @log[:support] << "#{name} → [구원] #{t} 건강 +#{heal}#{crit_str}#{roll_info}"
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
        rng = skill[:range]
        if t && @buffs[t] && @states[t] && BattleCalculator.in_range?(rng, @states[name][:pos], @states[t][:pos])
          @buffs[t][:guaranteed] = true
          @log[:support] << "#{name} → [백발백중] #{t} 이번 행동 반드시 성공 + 크리티컬 전환"
        else
          @log[:support] << "#{name} → [백발백중] #{t}: 사거리 밖 또는 대상 없음"
        end
      when '응원'
        t = targets.first
        rng = skill[:range]
        if t && @buffs[t] && @states[t] && BattleCalculator.in_range?(rng, @states[name][:pos], @states[t][:pos])
          @buffs[t][:luck_up] += 10
          @buffs[t][:new_luck_buff] = 10
          @log[:support] << "#{name} → [응원] #{t} 행운 +10 (2턴)"
        else
          @log[:support] << "#{name} → [응원] #{t}: 사거리 밖 또는 대상 없음"
        end
      when '즉발'
        t = targets.first
        rng = skill[:range]
        skill_to_reset = cmd[:target_pos].to_s.strip
        if t && @states[t] && BattleCalculator.in_range?(rng, @states[name][:pos], @states[t][:pos])
          if !skill_to_reset.empty?
            @cooldowns[t]&.delete(skill_to_reset)
            @log[:support] << "#{name} → [즉발] #{t}의 [#{skill_to_reset}] 쿨타임 초기화"
          else
            @log[:support] << "#{name} → [즉발] 대상 스킬명 미입력 (무효)"
          end
        else
          @log[:support] << "#{name} → [즉발] #{t}: 사거리 밖 또는 대상 없음"
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

  # ─── 이동 처리 ───────────────────────────────────────────────────
  def process_move
    occupied = {}
    @states.each_value do |s|
      pos = s[:pos].to_s.strip
      occupied[pos] = (occupied[pos] || 0) + 1 unless pos.empty?
    end

    @cmds.each do |name, cmd|
      next unless @states[name]
      next if @states[name][:hp] <= 0
      action = self.class.normalize(cmd[:action].to_s)
      next if action == '습격'

      # 슬리데린 2번: 1회 행동 포기(미행동)는 process_support/이동/공격에서 모두 스킵되며,
      # advance_buffs에서 무행동기록을 통해 다음 라운드 행운+10 부여

      if action == '순간이동'
        t    = cmd[:targets].first
        dest = cmd[:target_pos].to_s.strip
        if t && @states[t] && !dest.empty?
          if occupied[dest].to_i > 0 && @states[t][:pos] != dest
            @log[:move] << "#{name} → [순간이동] #{t}: #{dest}에 이미 다른 캐릭터가 있어 이동 불가"
          else
            old_pos = @states[t][:pos]
            occupied[old_pos] = (occupied[old_pos] || 1) - 1
            occupied[dest] = (occupied[dest] || 0) + 1
            @states[t][:pos] = dest
            @log[:move] << "#{name} → [순간이동] #{t}: #{old_pos} → #{dest}"
          end
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

      # 같은 칸 중복 배치 체크 (아군만 제한, 적과는 겹침 허용)
      target_occupant = @states.find { |n, s| n != name && s[:pos].to_s.strip == to && s[:hp] > 0 }
      if target_occupant && same_team?(name, target_occupant[0])
        @log[:move] << "#{name}: 이동 불가 — #{to}에 #{target_occupant[0]} 위치"
        next
      end

      occupied[from] = (occupied[from] || 1) - 1
      occupied[to]   = (occupied[to] || 0) + 1
      @states[name][:pos] = to
      @log[:move] << "#{name}: #{from} → #{to}"
    end
  end

  # ─── 공격 처리 ───────────────────────────────────────────────────
  def process_attack
    @cmds.each do |name, cmd|
      next unless @states[name]
      action = self.class.normalize(cmd[:action].to_s)
      next unless ATTACK_SKILLS.include?(action)
      next if @states[name][:hp] <= 0

      base = @base[name]
      next unless base

      if on_cooldown?(name, action)
        next
      end

      skill = @skills[action]

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

        tgt_agi = (tgt_base[:agi] + @buffs[tname][:agi_up]).to_i

        guaranteed = @buffs[name][:guaranteed]

        hit_detail = nil
        evade_detail = nil
        crit_detail = nil

        unless guaranteed
          hit_detail = BattleCalculator.hit_detail(caster_tec)
          unless hit_detail[:success]
            @log[:attack] << "#{name} → [#{action}] #{tname}: 빗나감 (#{BattleCalculator.roll_text('명중률', hit_detail)})"
            next
          end

          evade_detail = BattleCalculator.evade_detail(tgt_agi)
          if evade_detail[:success]
            @log[:attack] << "#{name} → [#{action}] #{tname}: 회피 (#{BattleCalculator.roll_text('회피율', evade_detail)})"
            next
          end
        end

        crit_detail = BattleCalculator.critical_detail(caster_luck)
        is_crit = guaranteed || crit_detail[:success]

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

        # 희생 처리
        actual_target = tname
        if @buffs[tname][:guardian]
          guardian = @buffs[tname][:guardian]
          if @states[guardian] && @states[guardian][:hp] > 0
            actual_target = guardian
            @log[:attack] << "#{guardian} → [희생] #{tname} 대신 피격"
          end
        end

        tgt_dur_final = ((@base[actual_target]&.dig(:dur) || 0) + @buffs[actual_target][:dur_up]).to_i

        # 그리핀도르 1번: 공격자(name)가 actual_target의 머리방향 전방 1마스에 있다면
        # actual_target의 내구도 +50% (적이 자신을 등지고 있을 때 받는 피해 감소)
        tgt_house   = @base[actual_target]&.dig(:house)
        tgt_passive = @base[actual_target]&.dig(:passive).to_s.strip
        if tgt_house == '그리핀도르' && tgt_passive == '1'
          tgt_facing = @base[actual_target][:facing].to_s.strip
          if BattleCalculator.in_front?(@states[actual_target][:pos], @states[name][:pos], tgt_facing)
            tgt_dur_final = (tgt_dur_final * 1.5).ceil
            @log[:attack] << "#{actual_target}: [그리핀도르] 공격자가 정면에 위치 — 내구도 1.5배 적용"
          end
        end

        effective_dur = @buffs[actual_target][:defense_stance] ? (tgt_dur_final * 1.5).ceil : tgt_dur_final
        dmg = BattleCalculator.calc_damage(raw_dmg, effective_dur)

        # 후플푸프 2번: 전투 중 1회 체력 0 이하 방지
        if @buffs[actual_target][:hufflepuff_guard] && @states[actual_target][:hp] - dmg <= 0
          dmg = @states[actual_target][:hp] - 1
          @buffs[actual_target][:used_hufflepuff_guard] = true
          @log[:attack] << "#{actual_target}: [후플푸프] 전투 중 1회 — 건강 0 이하 방지"
        end

        if @buffs[actual_target][:indomitable] && @states[actual_target][:hp] - dmg <= 0
          dmg = @states[actual_target][:hp] - 1
        end

        if @buffs[actual_target][:shield] > 0
          absorbed = [@buffs[actual_target][:shield], dmg].min
          @buffs[actual_target][:shield] -= absorbed
          dmg -= absorbed
        end

        @states[actual_target][:hp] = [@states[actual_target][:hp] - dmg, 0].max
        @buffs[actual_target][:took_damage_this_round] = true if dmg > 0

        crit_str = is_crit ? ' (크리티컬!)' : ''

        roll_parts = []
        roll_parts << BattleCalculator.roll_text('명중률', hit_detail) if hit_detail
        roll_parts << BattleCalculator.roll_text('회피율', evade_detail) if evade_detail && evade_detail[:roll]
        roll_parts << BattleCalculator.roll_text('크리티컬률', crit_detail) if crit_detail
        roll_info = roll_parts.empty? ? '' : " [#{roll_parts.join(' / ')}]"

        @log[:attack] << "#{name} → [#{action}] #{tname}: 명중#{crit_str}#{roll_info} / 피해 #{dmg} (건강 #{@states[actual_target][:hp]})"

        if action == '혼란'
          @buffs[tname][:confused] = (@buffs[tname][:confused] || 0) + 1
          cnt = @buffs[tname][:confused]
          @log[:attack] << "#{tname}: [혼란] 중첩 #{cnt}/5"
          if cnt >= 5
            @buffs[tname][:stunned] = true
            @buffs[tname][:confused] = 0
            @log[:attack] << "#{tname}: [혼란] 5중첩 — 행동 불가 (중첩 해소)"
          end
        end

        if action == '흙뿌리기'
          @buffs[tname][:blinded] = true
          @buffs[tname][:atk_up] -= (tgt_base[:atk] * 0.2).ceil
          @log[:attack] << "#{tname}: [시야차단] 마법능력 20% 감소 (이번 라운드)"
        end

        if @buffs[tname][:revenge_ready] && dmg > 0
          revenge_dmg = dmg * 2
          @states[name][:hp] = [@states[name][:hp] - revenge_dmg, 0].max
          @buffs[name][:took_damage_this_round] = true
          @log[:defense] << "#{tname} → [복수] #{name}: 피해 #{revenge_dmg}"
        end

        @log[:result] << "#{actual_target}: 건강 0 — 전투 불능." if @states[actual_target][:hp] <= 0
      end

      set_cooldown(name, action)
    end
  end

  # ─── 방어 처리 ───────────────────────────────────────────────────
  def process_defense
    @cmds.each do |name, cmd|
      next unless @states[name]
      action = self.class.normalize(cmd[:action].to_s)
      next unless DEFENSE_SKILLS.include?(action)
      next if @states[name][:hp] <= 0

      if on_cooldown?(name, action)
        next
      end

      base = @base[name]
      next unless base

      case action
      when '방어'
        t = cmd[:targets].first || name
        rng = '근접'
        if @buffs[t] && @states[t] && BattleCalculator.in_range?(rng, @states[name][:pos], @states[t][:pos])
          @buffs[t][:defense_stance] = true
          @log[:defense] << "#{name} → [방어] #{t} 방어태세 (내구도 1.5배)"
        else
          @log[:defense] << "#{name} → [방어] #{t}: 사거리 밖"
        end
      when '회피'
        @buffs[name][:agi_up] += 20
        @log[:defense] << "#{name} → [회피] 민첩 +20"
      when '복수'
        @buffs[name][:revenge_ready] = true
        @log[:defense] << "#{name} → [복수] 피격 시 2배 반격 대기"
      when '희생'
        t = cmd[:targets].first
        rng = '1'
        if t && @states[t] && BattleCalculator.in_range?(rng, @states[name][:pos], @states[t][:pos])
          @buffs[t][:guardian] = name
          @log[:defense] << "#{name} → [희생] #{t}의 피격 대신 받음"
        else
          @log[:defense] << "#{name} → [희생] #{t}: 사거리 밖 또는 대상 없음"
        end
      when '철벽'
        bonus = (base[:dur].to_i * 0.5).ceil
        valid = cmd[:targets].select do |t|
          @buffs[t] && @states[t] && BattleCalculator.in_range?('근접', @states[name][:pos], @states[t][:pos])
        end
        valid.each { |t| @buffs[t][:dur_up] += bonus }
        @log[:defense] << "#{name} → [철벽] #{valid.join(', ')} 내구도 +#{bonus}"
      when '주의분산'
        valid = cmd[:targets].select do |t|
          @buffs[t] && @states[t] && BattleCalculator.in_range?('근접', @states[name][:pos], @states[t][:pos])
        end
        valid.each { |t| @buffs[t][:agi_up] += 15 }
        @log[:defense] << "#{name} → [주의분산] #{valid.join(', ')} 민첩 +15"
      when '필사즉생'
        @buffs[name][:indomitable] = true
        @log[:defense] << "#{name} → [필사즉생] 이번 턴 건강 0 이하 방지"
      end

      set_cooldown(name, action)
    end
  end

  # ─── 슬리데린 2번 처리 (미행동 시 다음 라운드부터 행운+10 부여 예약) ──
  # process 흐름 안에서 advance_buffs 직전에 호출되도록 build_result_log에서 처리
  def mark_slytherin_skip(name)
    base = @base[name]
    return unless base
    return unless base[:house] == '슬리데린' && base[:passive].to_s.strip == '2'

    action = self.class.normalize(@cmds[name]&.dig(:action).to_s)
    if action.empty? || action == '미행동'
      @buffs[name][:new_slytherin_luck] = true
      @log[:support] << "#{name}: [슬리데린] 행동을 포기하고 상황을 살핍니다. (다음 라운드부터 행운 +10)"
    end
  end

  # ─── 결과 로그 ───────────────────────────────────────────────────
  def build_result_log
    @states.each_key do |name|
      mark_slytherin_skip(name)
    end

    @states.each do |name, state|
      shield_str = @buffs[name][:shield] > 0 ? " [보호막 #{@buffs[name][:shield]}]" : ""
      confused_str = @buffs[name][:confused].to_i > 0 ? " [혼란 #{@buffs[name][:confused]}/5]" : ""
      @log[:result] << "#{name}: 건강 #{state[:hp]}#{shield_str}#{confused_str}"
    end
  end
end
