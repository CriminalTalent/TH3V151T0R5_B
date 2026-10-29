# duel_manager.rb
# encoding: UTF-8
#
# 사용자끼리 결투 (1:1 / 2:2 / 4:4) — 1단계: 도전, 수락, 시작 위치 입력까지.
# 정산(공격/스킬 처리)은 아직 없다. 기존 BattleSession / settle_round 와 분리되어 있고
# sessions 해시에 들어가지 않는다. main.rb 에서 DUEL_ENABLED=true 일 때만 불러온다.

require 'set'

class DuelManager
  CHALLENGE_WAIT_SECONDS = 300
  PREP_WAIT_SECONDS = 300
  RETRY_SECONDS = 30
  TEAM_SIZES = [1, 2, 4].freeze
  COLS = %w[A B C D E F G].freeze
  ROWS = (1..8).to_a.freeze

  Duel = Struct.new(
    :id, :challenger, :team_a, :team_b, :accepted, :phase, :created_at,
    :prep_started_at, :positions, :reply_id, :announced_prep, :retry_after,
    :round, :stats, :hp, :cooldowns, :actions, :round_started_at, :announced_round,
    :next_round_at, :idle_rounds, :pending_post, :finishing, :ctx,
    keyword_init: true
  )

  def initialize
    @duels = {}
    @seen = Set.new
  end

  # main.rb 훅에서 호출한다. 결투 관련 글이면 true(호출부는 next), 아니면 false.
  def handle_message(username:, text:, status:, sessions:, runner_sheet:, bot_username:)
    username = username.to_s.sub(/\A@/, '').split('@').first.to_s.strip
    return false if username.empty?
    return false if username.casecmp?(bot_username.to_s)

    text = text.to_s
    cmd = parse_command(text)
    duel = duel_of(username)
    position_input = duel && duel.phase == :prep && text.match?(/\[[A-Ga-g][1-8]\]/)
    battle_input = duel && duel.phase == :battle && text.match?(ACTION_RE)
    return false unless cmd || position_input || battle_input

    sid = status['id'].to_s
    return true if @seen.include?(sid)

    @seen.add(sid)
    @seen = Set.new(@seen.to_a.last(1000)) if @seen.size > 2000

    case cmd && cmd[0]
    when :challenge then handle_challenge(username, cmd[1], status, sessions, runner_sheet)
    when :accept    then handle_accept(username, status)
    when :decline   then handle_decline(username, status)
    when :cancel    then handle_cancel(username, status)
    else battle_input ? handle_action(username, text, status) : handle_position(username, text, status)
    end
    true
  rescue => e
    puts "[결투] 처리 오류: #{e.class}: #{e.message}"
    puts e.backtrace.first(3)
    true
  end

  # 메인 루프에서 매번 호출한다. 만료 처리와 준비 라운드 진행을 맡는다.
  def tick(runner_sheet:, view_sheet: nil, scout_sheet: nil)
    now = Time.now
    @duels.values.each do |duel|
      case duel.phase
      when :pending
        if now - duel.created_at >= CHALLENGE_WAIT_SECONDS
          waiting = (members(duel) - duel.accepted.to_a).map { |n| "@#{n}" }.join(' ')
          finish(duel, "수락 대기 시간(5분)이 지나 결투가 취소되었습니다. (미수락: #{waiting})")
        end
      when :prep
        next if duel.retry_after && now < duel.retry_after

        unless duel.announced_prep
          announce_prep(duel, runner_sheet)
          next
        end

        if duel.positions.size >= members(duel).size
          complete_prep(duel, runner_sheet)
        elsif now - duel.prep_started_at >= PREP_WAIT_SECONDS
          missing = (members(duel) - duel.positions.keys).map { |n| "@#{n}" }.join(' ')
          finish(duel, "시작 위치 입력 시간(5분)이 지나 결투가 취소되었습니다. (미입력: #{missing})")
        end
      when :battle
        tick_battle(duel, now, view_sheet, scout_sheet)
      end
    end
  rescue => e
    puts "[결투] tick 오류: #{e.class}: #{e.message}"
  end

  # 결투(도전 대기 포함) 중인 참가자인지. 크리쳐 전투 시작 쪽에서 확인한다.
  def busy?(username)
    name = username.to_s.sub(/\A@/, '').split('@').first.to_s.strip
    !name.empty? && !duel_of(name).nil?
  end

  private

  def members(duel)
    duel.team_a + duel.team_b
  end

  def duel_of(username)
    @duels.values.find { |d| members(d).any? { |n| n.casecmp?(username) } }
  end

  def canon(duel, username)
    members(duel).find { |n| n.casecmp?(username) }
  end

  def parse_command(text)
    m = text.match(/\[결투\/([^\]]+)\]/)
    return [:challenge, m[1]] if m
    return [:accept] if text.include?('[결투수락]')
    return [:decline] if text.include?('[결투거절]')
    return [:cancel] if text.include?('[결투종료]') || text.include?('[결투취소]')

    nil
  end

  def allowed?(name)
    list = ENV['DUEL_ALLOWED_USERS'].to_s.split(',').map { |s| s.strip.downcase }.reject(&:empty?)
    list.empty? || list.include?(name.to_s.downcase)
  end

  def label(name, stats)
    stat = stats.find { |s| s[:name].to_s.casecmp?(name) }
    shown = stat ? stat[:display_name].to_s.strip : ''
    shown.empty? ? name : shown
  end

  def mark_reply(duel, status_id)
    sid = status_id.to_s
    duel.reply_id = sid if duel.reply_id.to_s.empty? || sid.to_i > duel.reply_id.to_i
  end

  def reply_user(username, message, status)
    post_battle_thread("@#{username} #{message}", true, status['id'])
  rescue => e
    puts "[결투] 안내 게시 오류: #{e.class}: #{e.message}"
    nil
  end

  def post(duel, text, reply_to = nil)
    tags = members(duel).map { |n| "@#{n}" }.join(' ')
    response = post_battle_thread("#{tags}\n\n#{text}", true, reply_to || duel.reply_id)
    mark_reply(duel, response['id']) if response && response['id']
    response
  rescue => e
    puts "[결투] 게시 오류: #{e.class}: #{e.message}"
    nil
  end

  def finish(duel, text, reply_to = nil)
    post(duel, text, reply_to)
    @duels.delete(duel.id)
    puts "[결투] [#{duel.id}] 종료"
  end

  def handle_challenge(username, raw, status, sessions, runner_sheet)
    usage = "형식: [결투/@상대] (1:1), [결투/@팀원/@상대1/@상대2] (2:2), " \
            "[결투/@팀원1/@팀원2/@팀원3/@상대1/@상대2/@상대3/@상대4] (4:4)\n" \
            "마지막 N명이 상대 팀이고, 앞의 N-1명이 내 팀입니다."
    typed = raw.split('/').map { |s| s.sub(/\A\s*@/, '').split('@').first.to_s.strip }.reject(&:empty?)

    if typed.empty? || typed.size.even? || !TEAM_SIZES.include?((typed.size + 1) / 2)
      return reply_user(username, "결투 인원을 확인해주세요. 지원: 1:1, 2:2, 4:4\n#{usage}", status)
    end
    if typed.any? { |n| n.casecmp?(username) } || typed.map(&:downcase).uniq.size != typed.size
      return reply_user(username, "본인 또는 같은 사람을 중복해서 지정할 수 없습니다.\n#{usage}", status)
    end

    names = [username] + typed
    unless names.all? { |n| allowed?(n) }
      return reply_user(username, "결투 기능은 현재 시험 중이라 일부 계정만 사용할 수 있습니다.", status)
    end

    stats = runner_sheet.read_base_stats
    resolved = names.map { |n| stats.find { |s| s[:name].to_s.casecmp?(n) || s[:id].to_s.casecmp?(n) } }
    unknown = names.each_with_index.select { |_, i| resolved[i].nil? }.map { |n, _| "@#{n}" }
    unless unknown.empty?
      return reply_user(username, "스탯 시트에 없는 계정이 있어 시작할 수 없습니다: #{unknown.join(' ')}", status)
    end
    downed = resolved.select { |s| s[:hp].to_i <= 0 }.map { |s| "@#{s[:name]}" }
    unless downed.empty?
      return reply_user(username, "체력이 0인 참가자가 있어 시작할 수 없습니다: #{downed.join(' ')}", status)
    end

    canon_names = resolved.map { |s| s[:name].to_s }
    busy = canon_names.select do |n|
      duel_of(n) || sessions.values.any? { |s| s.active && s.includes_runner?(n) }
    end
    unless busy.empty?
      return reply_user(username, "이미 다른 전투 또는 결투 중인 참가자가 있어 시작할 수 없습니다: #{busy.map { |n| "@#{n}" }.join(' ')}", status)
    end

    size = (typed.size + 1) / 2
    team_a = canon_names[0, size]
    team_b = canon_names[size, size]

    duel = Duel.new(
      id: status['id'].to_s, challenger: canon_names[0], team_a: team_a, team_b: team_b,
      accepted: Set.new([canon_names[0]]), phase: :pending, created_at: Time.now,
      prep_started_at: nil, positions: {}, reply_id: status['id'].to_s,
      announced_prep: false, retry_after: nil
    )
    @duels[duel.id] = duel
    puts "[결투] [#{duel.id}] 도전: #{team_a.join(',')} vs #{team_b.join(',')}"

    invited = members(duel).reject { |n| n == duel.challenger }.map { |n| "@#{n}" }.join(' ')
    post(duel, "[결투 도전] #{size}:#{size}\n" \
               "A팀: #{team_a.map { |n| label(n, stats) }.join(', ')}\n" \
               "B팀: #{team_b.map { |n| label(n, stats) }.join(', ')}\n\n" \
               "도전자: @#{duel.challenger}\n" \
               "#{invited} 님은 [결투수락] 또는 [결투거절]을 보내주세요.\n" \
               "수락 대기: 5분 (전원 수락 시 시작 위치 입력으로 넘어갑니다)", status['id'])
  end

  def handle_accept(username, status)
    duel = duel_of(username)
    unless duel && duel.phase == :pending
      return reply_user(username, "수락할 결투 도전이 없습니다.", status)
    end

    name = canon(duel, username)
    return nil if duel.accepted.include?(name)

    duel.accepted.add(name)
    mark_reply(duel, status['id'])
    remaining = members(duel) - duel.accepted.to_a
    if remaining.empty?
      duel.phase = :prep
      duel.prep_started_at = Time.now
      duel.announced_prep = false
      puts "[결투] [#{duel.id}] 전원 수락 — 준비 라운드"
    else
      post(duel, "@#{name} 님이 수락했습니다. 남은 인원: #{remaining.map { |n| "@#{n}" }.join(' ')}", status['id'])
    end
  end

  def handle_decline(username, status)
    duel = duel_of(username)
    unless duel && duel.phase == :pending
      return reply_user(username, "거절할 결투 도전이 없습니다.", status)
    end

    name = canon(duel, username)
    if name == duel.challenger
      finish(duel, "@#{name} 님이 도전을 취소했습니다.", status['id'])
    else
      finish(duel, "@#{name} 님이 결투를 거절해 취소되었습니다.", status['id'])
    end
  end

  def handle_cancel(username, status)
    duel = duel_of(username)
    return reply_user(username, "진행 중인 결투가 없습니다.", status) unless duel

    finish(duel, "@#{canon(duel, username)} 님이 결투를 종료했습니다.", status['id'])
  end

  def handle_position(username, text, status)
    duel = duel_of(username)
    return unless duel && duel.phase == :prep

    m = text.match(/\[([A-Ga-g][1-8])\]/)
    return unless m

    name = canon(duel, username)
    pos = m[1].upcase
    other = duel.positions.find { |n, p| p == pos && n != name }
    if other
      reply_user(username, "#{pos}은(는) #{other[0]}님이 이미 선택한 칸입니다. 다른 좌표를 입력해주세요.", status)
      return
    end

    duel.positions[name] = pos
    mark_reply(duel, status['id'])
    puts "[결투] [#{duel.id}] 시작 위치 등록: @#{name} → #{pos}"
  end

  def announce_prep(duel, runner_sheet)
    stats = runner_sheet.read_base_stats
    size = duel.team_a.size
    text = "[결투 준비 라운드] #{size}:#{size}\n\n" \
           "#{team_lines('A팀', duel.team_a, stats)}\n" \
           "#{team_lines('B팀', duel.team_b, stats)}\n\n" \
           "전장\n\n#{render_grid(duel, stats).join("\n")}\n" \
           "───────────────────\n" \
           "DM 또는 멘션으로 시작 위치를 입력해주세요.\n\n" \
           "형식: [좌표]\n" \
           "입력 대기: 5분\n" \
           "───────────────────"
    response = post(duel, text)
    if response && response['id'] && !response['partial']
      duel.announced_prep = true
      duel.retry_after = nil
      puts "[결투] [#{duel.id}] 준비 라운드 안내 송출"
    else
      duel.retry_after = Time.now + RETRY_SECONDS
      puts "[결투] [#{duel.id}] 준비 라운드 안내 송출 실패 — #{RETRY_SECONDS}초 뒤 재시도"
    end
  end

  def complete_prep(duel, runner_sheet)
    stats = runner_sheet.read_base_stats
    duel.stats = {}
    duel.hp = {}
    members(duel).each do |n|
      st = stats.find { |s| s[:name].to_s.casecmp?(n) }
      unless st
        return finish(duel, "스탯 시트에서 @#{n} 님의 정보를 찾지 못해 결투를 취소했습니다.")
      end
      if st[:hp].to_i <= 0
        return finish(duel, "@#{n} 님의 체력이 0이라 결투를 취소했습니다.")
      end
      duel.stats[n] = st
      duel.hp[n] = st[:hp].to_i
    end
    duel.cooldowns = Hash.new { |h, k| h[k] = {} }
    duel.actions = {}
    duel.round = 1
    duel.idle_rounds = 0
    duel.announced_round = false
    duel.round_started_at = nil
    duel.next_round_at = nil
    duel.pending_post = nil
    duel.finishing = false
    duel.phase = :battle
    puts "[결투] [#{duel.id}] 준비 완료 — 1라운드 시작"
  end

  def team_lines(title, list, stats)
    rows = list.map do |n|
      stat = stats.find { |s| s[:name].to_s.casecmp?(n) }
      hp = stat ? "#{stat[:hp].to_i}/#{stat[:max_hp].to_i}" : '-'
      "· #{label(n, stats)} (건강 #{hp})"
    end
    "[#{title}]\n#{rows.join("\n")}"
  end

  def assign_symbols(duel, stats)
    used = {}
    members(duel).each_with_object({}) do |name, map|
      chars = label(name, stats).delete(' ').chars
      pick = chars.find { |c| !used[c] && c != '□' } || (1..9).map(&:to_s).find { |c| !used[c] }
      used[pick] = true
      map[name] = pick
    end
  end

  def render_grid(duel, stats)
    symbols = assign_symbols(duel, stats)
    by_pos = {}
    duel.positions.each { |n, p| by_pos[p] = n }

    lines = []
    lines << '      A   B   C   D   E   F   G'
    ROWS.each do |row|
      cells = COLS.map do |col|
        name = by_pos["#{col}#{row}"]
        (name ? symbols[name] : '□').to_s.ljust(2)
      end
      lines << format('%2d   %s', row, cells.join(' '))
    end
    lines << ''
    lines << '[약칭]'
    duel.team_a.each { |n| lines << "#{symbols[n]} = #{label(n, stats)} (A팀)" }
    duel.team_b.each { |n| lines << "#{symbols[n]} = #{label(n, stats)} (B팀)" }
    lines << '□ = 빈칸'
    lines
  end
end

require_relative 'duel_battle'
require_relative 'duel_skills'
require_relative 'duel_settle'

DUEL_MANAGER = DuelManager.new
puts "[결투] 결투 기능 켜짐 (허용 계정: #{ENV['DUEL_ALLOWED_USERS'].to_s.strip.empty? ? '전체' : ENV['DUEL_ALLOWED_USERS']})"
