# web_state.rb
# encoding: UTF-8
#
# 레이드 웹 페이지(관전자/관리자/참여자)용 전투 상태 스냅샷.
# 전투봇 메인 루프가 이미 가진 메모리 값만 복사해 두며, 시트 API를 추가로
# 호출하지 않는다. 모든 진입점은 예외를 삼켜 전투 진행에 영향을 주지 않는다.

require 'json'

module WebState
  LOG_LIMIT = 30
  KEEP_FINISHED_SECONDS = 3600

  @mutex = Mutex.new
  @battles = {}

  module_function

  def enabled?
    ENV['WEB_ENABLED'].to_s.strip.downcase == 'true'
  end

  def show_dm?
    ENV['WEB_SHOW_DM'].to_s.strip.downcase == 'true'
  end

  def safe
    return unless enabled?
    yield
  rescue => e
    puts "[웹] 상태 갱신 오류(무시): #{e.class}: #{e.message}"
  end

  def entry_for(session)
    @battles[session.id.to_s] ||= {
      'id' => session.id.to_s,
      'runners' => [],
      'log' => [],
      'created_at' => Time.now.to_i
    }
  end

  def clean_name(name)
    name.to_s.gsub('@', '').strip
  end

  def creature_hash(creature)
    return {} unless creature.is_a?(Hash)
    {
      'name' => creature[:name].to_s,
      'hp' => creature[:hp].to_i,
      'max_hp' => [creature[:max_hp].to_i, creature[:hp].to_i, 1].max,
      'pos' => creature[:pos].to_s.upcase,
      'size' => (creature[:size] || '1x1').to_s,
      'cells' => (BattleGrid.creature_cells(creature) rescue []),
      'facing' => creature[:facing].to_s,
      'skill' => creature[:current_skill].to_s,
      'skill_cells' => (BattleBossPatterns.pattern_cells(creature) rescue []).to_a,
      'skill_target' => creature[:skill_target].to_s
    }
  end

  # 시트에서 읽은 러너 상태(이름/HP/최대HP/위치/표시이름)를 반영한다.
  def update_runners(session, runner_state)
    safe do
      @mutex.synchronize do
        e = entry_for(session)
        e['runners'] = Array(runner_state).select { |r| session.includes_runner?(r[:name]) }.map do |r|
          {
            'name' => clean_name(r[:name]),
            'display' => (r[:display_name].to_s.strip.empty? ? clean_name(r[:name]) : r[:display_name].to_s.strip),
            'hp' => r[:hp].to_i,
            'max_hp' => [r[:max_hp].to_i, r[:hp].to_i, 1].max,
            'pos' => r[:pos].to_s.upcase
          }
        end
        sync_meta(e, session)
      end
    end
  end

  # 봇이 게시한 안내/결과 글을 로그로 남긴다(첫 줄 멘션 태그 제거).
  def record_post(session, text)
    safe do
      body = text.to_s.split("\n---SPLIT---\n").join("\n")
      lines = body.split("\n")
      lines.shift while lines.first && (lines.first.strip.empty? || lines.first.strip.start_with?('@'))
      body = lines.join("\n").strip
      next if body.empty?
      @mutex.synchronize do
        e = entry_for(session)
        e['log'] << { 'at' => Time.now.to_i, 'round' => session.round.to_i, 'text' => body }
        e['log'] = e['log'].last(LOG_LIMIT)
        sync_meta(e, session)
      end
    end
  end

  # 매 루프마다 메모리 값(라운드/단계/제출자/위치)만 동기화한다.
  def sync_sessions(sessions)
    safe do
      @mutex.synchronize do
        live = {}
        sessions.each_value do |s|
          live[s.id.to_s] = true
          sync_meta(entry_for(s), s)
        end
        now = Time.now.to_i
        @battles.each_value do |e|
          next if live[e['id']]
          e['active'] = false
          e['ended_at'] ||= now
        end
        @battles.delete_if { |_id, e| e['ended_at'] && now - e['ended_at'] > KEEP_FINISHED_SECONDS }
      end
    end
  end

  def sync_meta(e, session)
    ctx = session.passive_ctx || {}
    positions = ctx[:positions] || {}
    e['round'] = session.round.to_i
    e['phase'] = session.phase.to_s
    e['active'] = session.active ? true : false
    e['ended_at'] = nil if session.active
    e['ended_at'] ||= Time.now.to_i unless session.active
    e['hidden'] = session.dm_visibility ? true : false
    e['bounty'] = session.bounty_pot ? true : false
    e['runner_names'] = session.runner_names.map { |n| clean_name(n) }
    e['dead'] = session.dead_runners.to_a.map { |n| clean_name(n) }
    e['submitted'] = session.actions.keys.map { |n| clean_name(n) }
    e['required'] = session.required_actions
    e['round_started_at'] = session.start_time.to_i
    e['action_wait'] = defined?(ACTION_WAIT_SECONDS) ? ACTION_WAIT_SECONDS : 300
    e['creature'] = creature_hash(session.creature)
    e['runners'].each do |r|
      pos = positions[r['name']].to_s.upcase
      r['pos'] = pos if pos.match?(/\A[A-G][1-8]\z/)
    end
    e['updated_at'] = Time.now.to_i
  end

  def public_battles
    @mutex.synchronize do
      list = @battles.values.reject { |e| e['hidden'] && !show_dm? }
      JSON.generate({
        'now' => Time.now.to_i,
        'cols' => BattleGrid::COLS,
        'rows' => BattleGrid::ROWS,
        'battles' => list.sort_by { |e| [e['active'] ? 0 : 1, -e['created_at'].to_i] }
      })
    end
  end
end
