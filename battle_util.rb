# encoding: UTF-8

def new_passive_ctx
  {
    round: 1,
    prev_took_damage: {},
    prev_action: {},
    slytherin_luck: Hash.new(0),
    guard_used: {},
    cooldowns: Hash.new { |h, k| h[k] = {} },
    once_used: Hash.new { |h, k| h[k] = {} },
    buffs: Hash.new { |h, k| h[k] = [] },
    shields: Hash.new(0),
    confusion: Hash.new(0),
    sure_hit: {},
    revenge: {},
    cover: {},
    survive_once: {},# encoding: UTF-8

def new_passive_ctx
  {
    round: 1,
    prev_took_damage: {},
    prev_action: {},
    slytherin_luck: Hash.new(0),
    guard_used: {},
    cooldowns: Hash.new { |h, k| h[k] = {} },
    once_used: Hash.new { |h, k| h[k] = {} },
    buffs: Hash.new { |h, k| h[k] = [] },
    shields: Hash.new(0),
    confusion: Hash.new(0),
    sure_hit: {},
    revenge: {},
    cover: {},
    survive_once: {},
    debuffs: Hash.new { |h, k| h[k] = [] },
    stun: {}
  }
end

def clean_html(text)
  text.to_s.gsub(/<br\s*\/?>/i, "\n")
           .gsub(/<\/p\s*>/i, "\n")
           .gsub(/<p[^>]*>/i, '')
           .gsub(/<[^>]*>/, '')
           .strip
end

def status_author_username(status)
  status.dig('account', 'username').to_s.strip
end

def bot_status?(status, bot_username)
  status_author_username(status) == bot_username.to_s.strip
end

def extract_usernames_from_status(status, content, bot_username)
  usernames = status['mentions'].to_a.map { |m| m['username'].to_s.strip }.reject(&:empty?).uniq
  usernames = content.scan(/@([A-Za-z0-9_]+)/).flatten.uniq if usernames.empty?
  usernames.reject { |u| u == bot_username }.uniq
end

def normalize_target(target)
  target.to_s.gsub('@', '').strip
end

def runner_alive?(runner)
  runner && runner[:hp].to_i > 0
end

    debuffs: Hash.new { |h, k| h[k] = [] },
    stun: {}
  }
end

def clean_html(text)
  text.to_s.gsub(/<br\s*\/?>/i, "\n")
           .gsub(/<\/p\s*>/i, "\n")
           .gsub(/<p[^>]*>/i, '')
           .gsub(/<[^>]*>/, '')
           .strip
end

def status_author_username(status)
  status.dig('account', 'username').to_s.strip
end

def bot_status?(status, bot_username)
  status_author_username(status) == bot_username.to_s.strip
end

def extract_usernames_from_status(status, content, bot_username)
  usernames = status['mentions'].to_a.map { |m| m['username'].to_s.strip }.reject(&:empty?).uniq
  usernames = content.scan(/@([A-Za-z0-9_]+)/).flatten.uniq if usernames.empty?
  usernames.reject { |u| u == bot_username }.uniq
end

def normalize_target(target)
  target.to_s.gsub('@', '').strip
end

def runner_alive?(runner)
  runner && runner[:hp].to_i > 0
end
