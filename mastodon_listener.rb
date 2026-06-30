require 'net/http'
require 'json'
require 'uri'

class MastodonListener
  def initialize(base_url, token)
    @base_url = base_url
    @token = token
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

  def reply_public(in_reply_to_id, text)
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
    puts "[Mastodon 오류] 답글 전송 실패: #{e.message}"
    nil
  end

  def send_dm(username, text)
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = {
      status: "@#{username} #{text}",
      visibility: 'direct'
    }.to_json

    res = http.request(req)
    data = JSON.parse(res.body)
    data['id']
  rescue => e
    puts "[Mastodon 오류] DM 전송 실패: #{e.message}"
    nil
  end
end
