# main.rb의 처음 require 섹션 바로 다음에 추가할 함수들

def fetch_public_statuses
  listener.fetch_public_statuses rescue []
end

def fetch_conversations
  listener.fetch_conversations rescue []
end

def fetch_notifications
  listener.fetch_notifications rescue []
end

def snapshot_current_dm_ids(set)
  fetch_conversations.each { |c| set.add(c['last_status']['id']) if c['last_status'] && c['last_status']['id'] } rescue nil
end

def snapshot_current_notification_ids(set)
  fetch_notifications.each { |n| set.add(n['id']) if n && n['id'] } rescue nil
end

def clean_html(html_text)
  html_text.nil? ? '' : html_text.gsub(/<[^>]+>/, '')
end

def bot_status?(status, bot_name)
  acct = status.dig('account', 'username').to_s.gsub('@', '').strip
  acct == bot_name.to_s.gsub('@', '').strip
end

def boss_skill_defined?(creature_sheet, skill_name)
  return false if skill_name.to_s.strip.empty?
  begin
    rows = creature_sheet.read_range('보스스킬', 'A:A')
    rows&.any? { |row| row[0].to_s.strip == skill_name.to_s.strip }
  rescue; false; end
end

def apply_boss_skill_definition!(creature, creature_sheet)
  return unless creature && creature[:current_skill]
  begin
    rows = creature_sheet.read_range('보스스킬', 'A:Z')
    target_row = rows.find { |row| row[0].to_s.strip == creature[:current_skill].to_s.strip }
    return unless target_row
    creature[:damage] = target_row[2].to_i if target_row[2]
    creature[:skill_range_default] = target_row[3].to_s if target_row[3]
    creature[:omen] = target_row[4].to_s if target_row[4]
  rescue => e
    puts "[apply_boss_skill_definition 오류] #{e.message}"
  end
end

def refresh_creature_skill!(creature, creature_sheet)
  return unless creature
  creature[:current_skill] = ''
  creature[:skill_target] = ''
  creature[:skill_range] = ''
end

def extract_usernames_from_status(status, content, bot_username)
  usernames = Set.new
  if status && status['mentions'] && status['mentions'].is_a?(Array)
    status['mentions'].each do |mention|
      username = mention['username'].to_s.gsub('@', '').strip
      next if username.empty? || (bot_username && username == bot_username.to_s.gsub('@', '').strip)
      usernames.add(username)
    end
  end
  usernames.to_a
rescue; []; end

def creature_from_start_content(content, creature_sheet)
  match = content.to_s.match(/\[전투시작(?:\/([^\]]+))?\]/)
  creature_name = match ? match[1]&.strip : nil
  begin
    rows = creature_sheet.read_range('스탯', 'A:Z')
    target = creature_name ? rows.find { |row| row[1].to_s.strip == creature_name.to_s.strip } : nil
    target ||= rows[1]
    { name: target[1].to_s.strip, hp: target[4].to_i, max_hp: target[4].to_i, pos: 'D4', size: '1x1', current_skill: '', skill_target: '', skill_range: '', omen: '', pattern: '', pattern_cells: '' }
  rescue; { name: '크리쳐', hp: 100, max_hp: 100, pos: 'D4', size: '1x1' }; end
end

def merge_runner_state(view_sheet, runner_sheet, runner_names, default_pos)
  state = []
  begin
    view_rows = view_sheet.read_range('D3', 'A:Z') rescue []
    runner_rows = runner_sheet.read_range('스탯', 'A:Z') rescue []
    runner_names.each do |name|
      view_row = view_rows.find { |row| row[1].to_s.strip == name.to_s.strip } rescue nil
      runner_row = runner_rows.find { |row| row[1].to_s.strip == name.to_s.strip } rescue nil
      state << { name: name.to_s, hp: view_row ? view_row[3].to_i : 50, max_hp: runner_row ? runner_row[4].to_i : 50, pos: default_pos, display_name: name.to_s }
    end
  rescue => e
    puts "[merge_runner_state 오류] #{e.message}"
  end
  state
end

def record_battle_action(username, text, actions, processed_messages, processed_set, processed_id, runner_names, view_sheet, runner_sheet, creature, listener, ctx)
  return unless runner_names.include?(username.to_s)
  username_str = username.to_s
  processed_set.add(processed_id)
  
  if text.to_s.match?(/\[이동\/([A-Ga-g][1-8])\]/)
    pos = text.to_s.match(/\[이동\/([A-Ga-g][1-8])\]/)[1].upcase
    actions[username_str] = { type: '이동', target: pos }
    (ctx[:positions] ||= {})[username_str] = pos
  elsif text.to_s.match?(/\[([^\]\/]+)(?:\/([^\]]+))?\]/)
    m = text.to_s.match(/\[([^\]\/]+)(?:\/([^\]]+))?\]/)
    actions[username_str] = { type: '공격', skill: m[1].to_s.strip, target: m[2].to_s.strip }
  end
rescue => e
  puts "[record_battle_action 오류] #{e.message}"
end

def settle_round(actions, runner_names, runner_sheet, creature_sheet, view_sheet, creature, ctx)
  [[],[]]
end

def build_result_text(runner_tags, round, creature, actions, runner_names, log, runner_state, view_sheet, timeout: false, shields: nil)
  ["#{runner_tags}\n\n[#{round}라운드 정산]"]
end
