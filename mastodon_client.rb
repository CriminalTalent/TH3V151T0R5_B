require 'net/http'
require 'json'
require 'uri'

class MastodonClient
  def initialize(base_url, token)
    @base_url = base_url
    @token = token
  end

  def post_status(text, visibility = 'public')
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = { status: text, visibility: visibility }.to_json

    res = http.request(req)
    data = JSON.parse(res.body)
    puts "[Mastodon] 툿 전송 완료 (#{visibility}): #{data['id']}"
    data['id']
  rescue => e
    puts "[Mastodon 오류] #{e.message}"
    nil
  end

  def reply_status(text, in_reply_to_id, visibility = 'public')
    uri = URI("#{@base_url}/api/v1/statuses")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{@token}"
    req['Content-Type'] = 'application/json'
    req.body = {
      status: text,
      visibility: visibility,
      in_reply_to_id: in_reply_to_id
    }.to_json

    res = http.request(req)
    data = JSON.parse(res.body)
    puts "[Mastodon] 스레드 툿 전송 완료 (#{visibility}): #{data['id']}"
    data['id']
  rescue => e
    puts "[Mastodon 오류] #{e.message}"
    nil
  end

  def post_public(text)
    post_status(text, 'public')
  end

  def reply_public(text, in_reply_to_id)
    reply_status(text, in_reply_to_id, 'public')
  end
end
