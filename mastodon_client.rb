# mastodon_client.rb
require 'faraday'
require 'json'

class MastodonClient
  MAX_TOOT_LENGTH = 500  # 500자 제한

  def initialize(base_url, token)
    @base_url = base_url
    @token = token

    @conn = Faraday.new(url: @base_url) do |f|
      f.request :url_encoded
      f.response :raise_error
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
    end
  end

  def get(path, params = {})
    res = @conn.get(path) do |req|
      req.headers['Authorization'] = "Bearer #{@token}"
      req.headers['Content-Type'] = 'application/json'
      req.params.update(params) if params && !params.empty?
    end
    JSON.parse(res.body)
  end

  def post(path, body = {})
    res = @conn.post(path) do |req|
      req.headers['Authorization'] = "Bearer #{@token}"
      req.headers['Content-Type'] = 'application/json'
      req.body = body.to_json
    end
    JSON.parse(res.body)
  end

  def reply(status_hash, message)
    in_reply_to_id = status_hash["id"] || status_hash[:id]
    post("/api/v1/statuses", {
      status: message,
      in_reply_to_id: in_reply_to_id,
      visibility: "unlisted"
    })
  rescue => e
    puts "[MastodonClient] reply 실패: #{e.message}"
    nil
  end

  # 여러 사용자 멘션하면서 답장
  def reply_with_mentions(status_hash, message, user_ids)
    in_reply_to_id = status_hash["id"] || status_hash[:id]
    
    mentions = user_ids.map { |id| "@#{id}" }.join(' ')
    full_message = "#{mentions}\n#{message}"
    
    # 500자 넘으면 스레드로 분할
    if full_message.length > MAX_TOOT_LENGTH
      reply_with_mentions_thread(status_hash, message, user_ids)
    else
      post("/api/v1/statuses", {
        status: full_message,
        in_reply_to_id: in_reply_to_id,
        visibility: "unlisted"
      })
    end
  rescue => e
    puts "[MastodonClient] reply_with_mentions 실패: #{e.message}"
    nil
  end

  # 긴 메시지를 스레드로 분할해서 발송
  def reply_with_mentions_thread(status_hash, message, user_ids)
    in_reply_to_id = status_hash["id"] || status_hash[:id]
    mentions = user_ids.map { |id| "@#{id}" }.join(' ')
    mentions_length = mentions.length + 1  # +1 for newline
    
    # 메시지를 500자 이하 청크로 분할
    chunks = split_message(message, MAX_TOOT_LENGTH - mentions_length)
    
    last_status = nil
    chunks.each_with_index do |chunk, index|
      full_message = "#{mentions}\n#{chunk}"
      
      begin
        result = post("/api/v1/statuses", {
          status: full_message,
          in_reply_to_id: in_reply_to_id,
          visibility: "unlisted"
        })
        
        # 다음 메시지는 이전 메시지에 답장
        in_reply_to_id = result["id"] if result
        last_status = result
        
        # API 제한 방지를 위해 0.5초 대기
        sleep 0.5 if index < chunks.length - 1
        
      rescue => e
        puts "[MastodonClient] 스레드 #{index + 1}/#{chunks.length} 발송 실패: #{e.message}"
      end
    end
    
    last_status
  end

  def stream(limit: 20, interval: 2, dismiss: false)
    since_id = nil
    
    # 봇 시작 시 현재 최신 알림 ID를 since_id로 설정 (이전 알림 무시)
    begin
      initial_notifications = get("/api/v1/notifications", { limit: 1 })
      if initial_notifications.any?
        since_id = initial_notifications.first["id"]
        puts "[MastodonClient] 봇 시작 - 최신 알림 ID: #{since_id}"
        puts "[MastodonClient] 이전 알림은 무시하고 새 알림만 처리합니다."
      end
    rescue => e
      puts "[MastodonClient] 초기 알림 ID 가져오기 실패: #{e.message}"
    end

    loop do
      notifications = get("/api/v1/notifications", { limit: limit, since_id: since_id })
      notifications = notifications.reverse

      notifications.each do |n|
        since_id = n["id"] if since_id.nil? || n["id"].to_i > since_id.to_i

        yield n

        if dismiss
          begin
            post("/api/v1/notifications/#{n['id']}/dismiss", {})
          rescue => e
            puts "[MastodonClient] dismiss 실패: #{e.message}"
          end
        end
      end

      sleep interval
    end
  end

  private

  # 메시지를 자연스럽게 분할 (줄바꿈 기준)
  def split_message(message, max_length)
    return [message] if message.length <= max_length
    
    chunks = []
    current_chunk = ""
    
    lines = message.split("\n")
    
    lines.each do |line|
      # 한 줄이 max_length보다 길면 강제 분할
      if line.length > max_length
        # 현재 청크가 있으면 저장
        chunks << current_chunk.strip if current_chunk.length > 0
        
        # 긴 줄을 강제 분할
        while line.length > 0
          chunks << line[0...max_length]
          line = line[max_length..-1] || ""
        end
        
        current_chunk = ""
      else
        # 현재 청크에 추가했을 때 max_length를 넘으면
        if (current_chunk + "\n" + line).length > max_length
          chunks << current_chunk.strip if current_chunk.length > 0
          current_chunk = line
        else
          current_chunk += (current_chunk.empty? ? "" : "\n") + line
        end
      end
    end
    
    # 마지막 청크 추가
    chunks << current_chunk.strip if current_chunk.length > 0
    
    chunks
  end
end
