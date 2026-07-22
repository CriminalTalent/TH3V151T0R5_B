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

  def mark_thread_id(status_id)
    return if status_id.to_s.strip.empty?
    @thread_ids.add(status_id.to_s)
    @thread_reply_id = status_id.to_s
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
