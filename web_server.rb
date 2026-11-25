# web_server.rb
# encoding: UTF-8
#
# 의존성 없는(표준 라이브러리 socket만 사용) 초소형 HTTP 서버.
# WEB_ENABLED=true 일 때만 별도 스레드로 뜨며, 127.0.0.1에만 바인딩한다.
# 외부 공개는 nginx 리버스 프록시로 한다.

require 'socket'

module WebServer
  ROOT = File.join(__dir__, 'web')
  PAGES = {
    '/' => 'spectator.html',
    '/spectator' => 'spectator.html'
  }.freeze

  module_function

  def start!
    return unless WebState.enabled?
    host = ENV['WEB_HOST'].to_s.strip.empty? ? '127.0.0.1' : ENV['WEB_HOST'].strip
    port = (ENV['WEB_PORT'] || '4567').to_i
    server = TCPServer.new(host, port)
    puts "[웹] 레이드 페이지 서버 시작 http://#{host}:#{port}/"
    Thread.new do
      loop do
        client = server.accept
        Thread.new(client) { |c| handle(c) }
      rescue => e
        puts "[웹] accept 오류: #{e.class}: #{e.message}"
        sleep 1
      end
    end
  rescue => e
    puts "[웹] 서버 시작 실패(전투봇은 계속 동작): #{e.class}: #{e.message}"
  end

  def handle(client)
    client.read_timeout = 5 if client.respond_to?(:read_timeout=)
    request_line = client.gets.to_s
    method, target, = request_line.split(' ')
    while (line = client.gets) && line != "\r\n" && line != "\n"; end
    path = target.to_s.split('?').first.to_s
    path = path.chomp('/') if path.length > 1

    if method != 'GET'
      respond(client, 405, 'text/plain; charset=utf-8', 'Method Not Allowed')
    elsif path == '/api/battles'
      respond(client, 200, 'application/json; charset=utf-8', WebState.public_battles)
    elsif PAGES[path]
      file = File.join(ROOT, PAGES[path])
      respond(client, 200, 'text/html; charset=utf-8', File.read(file, encoding: 'UTF-8'))
    else
      respond(client, 404, 'text/plain; charset=utf-8', 'Not Found')
    end
  rescue => e
    puts "[웹] 요청 처리 오류: #{e.class}: #{e.message}"
    respond(client, 500, 'text/plain; charset=utf-8', 'Error') rescue nil
  ensure
    client.close rescue nil
  end

  def respond(client, code, type, body)
    reason = { 200 => 'OK', 404 => 'Not Found', 405 => 'Method Not Allowed', 500 => 'Internal Server Error' }[code]
    body = body.to_s.b
    client.write("HTTP/1.1 #{code} #{reason}\r\n" \
                 "Content-Type: #{type}\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Cache-Control: no-store\r\n" \
                 "Connection: close\r\n\r\n")
    client.write(body)
  end
end
