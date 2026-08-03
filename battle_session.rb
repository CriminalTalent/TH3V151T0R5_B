# encoding: UTF-8

class BattleSession
  attr_accessor :id, :auto_mode, :mode, :round, :active, :announced, :actions,
                :start_time, :auto_next_round_timer, :creature, :runner_names,
                :runner_tags, :processed_messages, :passive_ctx, :thread_reply_id,
                :thread_ids, :dead_runners, :phase, :awaiting_boss

  def initialize(id:, mode:, runner_names:, creature:, thread_reply_id: nil, round: 1)
    @id = id.to_s
    @mode = mode # :dm 또는 :public
    @round = round.to_i <= 0 ? 1 : round.to_i
    @active = true
    @announced = false
    @actions = {}
    @start_time = Time.now
    @auto_next_round_timer = nil
    @creature = creature
    @runner_names = runner_names.map { |n| n.to_s.gsub('@', '').strip }.reject(&:empty?).uniq
    @runner_tags = @runner_names.map { |u| "@#{u}" }.join(' ')
    @processed_messages = {}
    @passive_ctx = new_passive_ctx
    @thread_reply_id = thread_reply_id
    @thread_ids = Set.new
    @thread_ids.add(thread_reply_id.to_s) if thread_reply_id
    @thread_ids.add(@id)
    @dead_runners = []
    @phase = :prep
    @awaiting_boss = false
  end

  # 전투불가(체력 0) 러너를 제외한, 이번 라운드 행동이 필요한 인원 수
  def required_actions
    (@runner_names - @dead_runners.to_a).size
  end

  def mark_dead_runners(names)
    @dead_runners = (@dead_runners.to_a | names.map { |n| n.to_s.gsub('@', '').strip }).select { |n| @runner_names.include?(n) }
  end

  def dm_mode?
    @mode == :dm
  end

  def total_runners
    @runner_names.size
  end

  def includes_runner?(username)
    @runner_names.include?(username.to_s.gsub('@', '').strip)
  end

  # 다음 봇 안내가 답장으로 달릴 대상을 갱신합니다. 봇이 새로 올린 글이든,
  # 세션에 실제로 반영된 사용자 메시지(행동 등록/시작 위치 입력/보스행동커맨드
  # 적용)든 상관없이, 숫자로 비교했을 때 더 나중(더 큰 ID)인 쪽이 항상
  # 다음 답장 대상이 되도록 합니다. 이렇게 하면 "봇 안내 → 유저 답장 →
  # 봇 다음 안내"처럼 대화가 실제로 오간 순서 그대로 스레드가 이어집니다.
  def mark_thread_id(status_id)
    sid = status_id.to_s.strip
    return if sid.empty?
    @thread_ids.add(sid)

    if @thread_reply_id.to_s.strip.empty? || sid.to_i > @thread_reply_id.to_i
      @thread_reply_id = sid
    end
  end

  def related_to_status?(status)
    sid = status['id'].to_s
    rid = status['in_reply_to_id'].to_s
    @thread_ids.include?(sid) || (!rid.empty? && @thread_ids.include?(rid))
  end

  def reset_for_next_round!
    @round += 1
    @active = true
    @announced = false
    @start_time = Time.now
    @actions = {}
    @processed_messages = {}
    @auto_next_round_timer = nil
  end

  def finished?
    !@active && @auto_next_round_timer.nil?
  end
end
