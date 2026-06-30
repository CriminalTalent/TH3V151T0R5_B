require 'net/http'
require 'json'
require 'uri'

class MastodonListener
  def initialize(base_url, token)
    @base_url = base_url.to_s.sub(%r{/\z}, '')
    @token = token
  end

  def post_public(text)
    request_status(
      status: text,
      visibility: 'public'
    )
  end

  def reply_public(in_reply_to_id, text)
    request_status(
      status: text,
      visibility: 'public',
      in_reply_to_id: in_reply_to_id
    )
  end

  def send_dm(username, text)
    request_status(
      status: "@#{username} #{text}",
      visibility: 'direct'
    )
  end

  private

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
    puts "[Mastodon 오류] #{e.class}: #{e.message}"
    nil
  end
end
