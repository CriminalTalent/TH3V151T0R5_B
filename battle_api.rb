# encoding: UTF-8

def post_status_raw(text, visibility:, reply_to_id: nil)
  uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/statuses")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"
  req.set_form_data(
    status: text,
    visibility: visibility,
    in_reply_to_id: reply_to_id
  )

  res = http.request(req)
  unless res.code.to_i.between?(200, 299)
    puts "[전투봇 오류] 툿 발송 실패: #{res.code} #{res.body}"
    return nil
  end

  JSON.parse(res.body)
rescue => e
  puts "[전투봇 오류] 툿 발송 예외: #{e.class}: #{e.message}"
  nil
end

def post_battle_thread(text, dm_mode, reply_id)
  visibility = dm_mode ? 'direct' : 'public'
  post_status_raw(text, visibility: visibility, reply_to_id: reply_id)
end

def fetch_public_statuses
  uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/timelines/public?local=true")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"

  res = http.request(req)
  return [] unless res.code == '200'

  JSON.parse(res.body)
rescue => e
  puts "[전투봇 오류] 공개 타임라인 조회 실패: #{e.class}: #{e.message}"
  []
end

def fetch_conversations
  uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/conversations")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"

  res = http.request(req)
  return [] unless res.code == '200'

  JSON.parse(res.body)
rescue => e
  puts "[전투봇 오류] DM 조회 실패: #{e.class}: #{e.message}"
  []
end

def fetch_notifications(since_id: nil)
  uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/notifications")
  params = { limit: 30 }
  params[:since_id] = since_id.to_s if since_id
  uri.query = URI.encode_www_form(params)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"

  res = http.request(req)
  return [] unless res.code == '200'

  JSON.parse(res.body).select { |n| n['type'] == 'mention' && n['status'] }
rescue => e
  puts "[전투봇 오류] 알림 조회 실패: #{e.class}: #{e.message}"
  []
end

def snapshot_current_dm_ids(processed_dm_ids)
  fetch_conversations.each do |conv|
    last_status = conv['last_status']
    next unless last_status && last_status['id']
    processed_dm_ids.add(last_status['id'])
  end
end

def snapshot_current_notification_ids(processed_notification_ids)
  fetch_notifications.each do |n|
    processed_notification_ids.add(n['id']) if n['id']
  end
end
