require 'net/http'
require 'json'
require 'uri'

class MastodonClient
  def initialize(base_url, token)
    @base_url = base_url.to_s.sub(%r{/\z}, '')
    @token = token
  end

  def post_status(text, visibility = 'public')
    request_status(
      status: text,
      visibility: visibility
    )
  end

  def reply_status(text, in_reply_to_id, visibility = 'public')
    request_status(
      status: text,
      visibility: visibility,
      in_reply_to_id: in_reply_to_id
    )
  end

  def post_public(text)
    post_status(text, 'public')
  end

  def reply_public(in_reply_to_id, text)
    reply_status(text, in_reply_to_id, 'public')
  end

  def send_dm(username, text)
    request_status(
      status: "@#{username} #{text}",
      visibility: 'direct'
    )
  end

  def public_timeline(local: true, limit: 20)
    query = URI.encode_www_form(local: local, limit: limit)
    request_get("/api/v1/timelines/public?#{query}") || []
  end

  def conversations(limit: 20)
    query = URI.encode_www_form(limit: limit)
    request_get("/api/v1/conversations?#{query}") || []
  end

  private

  def request_get(path)
    uri = URI("#{@base_url}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 30
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    res = http.request(req)
    parse_json_response(res)
  rescue => e
    puts "[Mastodon 오류] GET #{path}: #{e.class}: #{e.message}"
    nil
  end

  def request_status(payload)
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 30
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = payload.to_json
    res = http.request(req)
    unless res.code.start_with?('2')
      puts "[Mastodon 오류] HTTP #{res.code}"
      puts res.body
      return nil
    end
    data = JSON.parse(res.body)
    data['id']
  rescue JSON::ParserError => e
    puts "[Mastodon 오류] JSON 파싱 실패: #{e.message}"
    nil
  rescue => e
    puts "[Mastodon 오류] POST status: #{e.class}: #{e.message}"
    nil
  end

  def parse_json_response(res)
    unless res.code.start_with?('2')
      puts "[Mastodon 오류] HTTP #{res.code}"
      puts res.body
      return nil
    end
    JSON.parse(res.body)
  rescue JSON::ParserError => e
    puts "[Mastodon 오류] JSON 파싱 실패: #{e.message}"
    nil
  end
end
