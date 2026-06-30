# mastodon_listener.rb
require 'net/http'
require 'json'
require 'uri'

class MastodonListener
  def initialize(base_url, token)
    @base_url = base_url
    @token = token
    @last_notification_id = 0
  end

  def get_notifications
    uri = URI("#{@base_url}/api/v1/notifications")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{@token}"

    res = http.request(req)
    JSON.parse(res.body)
  rescue => e
    puts "[Mastodon 오류] 알림 조회 실패: #{e.message}"
    []
  end

  def get_account_info
    uri = URI("#{@base_url}/api/v1/accounts/verify_credentials")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{@token}"

    res = http.request(req)
    JSON.parse(res.body)
  rescue => e
    puts "[Mastodon 오류] 계정 정보 조회 실패: #{e.message}"
    nil
  end

  def post_public(text)
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = { status: text, visibility: 'public' }.to_json

    res = http.request(req)
    data = JSON.parse(res.body)
    data['id']
  rescue => e
    puts "[Mastodon 오류] 공개 포스트 전송 실패: #{e.message}"
    nil
  end

  def reply_public(text, in_reply_to_id)
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = {
      status: text,
      visibility: 'public',
      in_reply_to_id: in_reply_to_id
    }.to_json

    res = http.request(req)
    data = JSON.parse(res.body)
    data['id']
  rescue => e
    puts "[Mastodon 오류] 스레드 포스트 전송 실패: #{e.message}"
    nil
  end

  def send_dm(account_id, text)
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = { 
      status: "@#{account_id} #{text}", 
      visibility: 'direct' 
    }.to_json

    res = http.request(req)
    data = JSON.parse(res.body)
    data['id']
  rescue => e
    puts "[Mastodon 오류] DM 전송 실패: #{e.message}"
    nil
  end

  def parse_mentions(status_text)
    status_text.scan(/@(\w+)/).flatten
  end
end
