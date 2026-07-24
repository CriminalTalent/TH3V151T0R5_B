require 'json'
require 'net/http'
require 'uri'
require_relative 'toot_builder'
require_relative 'mastodon_client'

TOOT_MAX_CHARS = (ENV['TOOT_MAX_CHARS'] || '950').to_i

def force_utf8(value)
  s = value.to_s
  s = s.dup.force_encoding('UTF-8')
  s.valid_encoding? ? s : s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
end

def split_toot_text(text, limit = TOOT_MAX_CHARS)
  text = force_utf8(text)
  return [text] if limit <= 0 || text.length <= limit
  lines = text.split("\n", -1)
  header = lines.first.to_s.start_with?('@') ? lines.first.strip : nil
  chunks = []
  current = ''
  lines.each do |line|
    candidate = current.empty? ? line : "#{current}\n#{line}"
    if candidate.length <= limit
      current = candidate
      next
    end
    chunks << current unless current.empty?
    base = header ? "#{header}\n" : ''
    if (base + line).length <= limit
      current = base + line
      next
    end
    room = [limit - base.length, 1].max
    pieces = line.chars.each_slice(room).map(&:join)
    pieces.each_with_index do |piece, index|
      chunks << current if index.positive? && !current.empty?
      current = base + piece
    end
  end
  chunks << current unless current.empty?
  chunks
end

def mastodon_client
  @mastodon_client ||= MastodonClient.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])
end

def post_battle_thread(text, dm = false, reply_to_id = nil, runner_tags = '')
  visibility = dm ? 'direct' : 'public'
  parts = text.split("\n---SPLIT---\n")
  chunks = parts.flat_map { |p| split_toot_text(p) }.reject { |c| c.to_s.strip.empty? }
  expected_count = chunks.length
  thread_ids = []
  parent_id = reply_to_id
  chunks.each do |chunk|
    response = if parent_id
      mastodon_client.reply_status(chunk, parent_id, visibility)
    else
      mastodon_client.post_status(chunk, visibility)
    end
    if response
      thread_ids << response
      parent_id = response
    else
      break
    end
    sleep(1.2)
  end

  return nil if thread_ids.empty?

  {
    'id' => thread_ids.last,
    'all_ids' => thread_ids,
    'partial' => thread_ids.length < expected_count,
    'sent_count' => thread_ids.length,
    'expected_count' => expected_count
  }
rescue => e
  puts "[post_battle_thread 오류] #{e.class}: #{e.message}"
  return nil unless defined?(thread_ids) && thread_ids && thread_ids.length > 0

  {
    'id' => thread_ids.last,
    'all_ids' => thread_ids,
    'partial' => true,
    'sent_count' => thread_ids.length,
    'expected_count' => defined?(expected_count) ? expected_count : thread_ids.length
  }
end

def fetch_public_statuses
  mastodon_client.public_timeline(local: true, limit: 20)
rescue => e
  puts "[fetch_public_statuses 오류] #{e.class}: #{e.message}"
  []
end

def fetch_conversations
  mastodon_client.conversations(limit: 20)
rescue => e
  puts "[fetch_conversations 오류] #{e.class}: #{e.message}"
  []
end

def fetch_notifications
  mastodon_client.notifications(limit: 20)
rescue => e
  puts "[fetch_notifications 오류] #{e.class}: #{e.message}"
  []
end

def snapshot_current_dm_ids(set)
  fetch_conversations.each { |c| set.add(c['last_status']['id']) if c['last_status'] && c['last_status']['id'] }
rescue => e
  puts "[snapshot_current_dm_ids 오류] #{e.message}"
end

def snapshot_current_notification_ids(set)
  fetch_notifications.each { |n| set.add(n['id']) if n && n['id'] }
rescue => e
  puts "[snapshot_current_notification_ids 오류] #{e.message}"
end

def clean_html(html_text)
  html_text.nil? ? '' : html_text.gsub(/<[^>]+>/, '')
end

def bot_status?(status, bot_name)
  acct = status.dig('account', 'username').to_s.gsub('@', '').strip
  acct == bot_name.to_s.gsub('@', '').strip
end

def extract_usernames_from_status(status, content, bot_username)
  usernames = Set.new
  if status && status['mentions'] && status['mentions'].is_a?(Array)
    status['mentions'].each do |mention|
      username = mention['username'].to_s.gsub('@', '').strip
      next if username.empty?
      next if bot_username && username == bot_username.to_s.gsub('@', '').strip
      usernames.add(username)
    end
  end
  usernames.to_a
rescue => e
  []
end

def select_auto_skill(creature, creature_sheet)
  return nil unless creature
  begin
    rows = creature_sheet.read_range('보스스킬', 'A:Z')
    return nil if rows.empty?
    available = []
    rows[1..].each do |row|
      skill_name = row[0].to_s.strip
      next if skill_name.empty?
      category = row[12].to_s.strip
      priority = row[13].to_i
      available << { name: skill_name, category: category, priority: priority }
    end
    return nil if available.empty?
    priority_map = { '필수' => 1, '생존' => 2, '범위' => 3, '단일' => 4, '기본공격' => 5 }
    available.sort_by { |s| [priority_map[s[:category]] || 99, -s[:priority]] }.first[:name]
  rescue => e
    puts "[select_auto_skill 오류] #{e.message}"
    nil
  end
end
