# battle_bot.rb
require 'bundler/setup'
require 'dotenv/load'
require 'set'

require_relative 'sheet_manager'
require_relative 'mastodon_client'
require_relative 'command_parser'
require_relative 'battle_timer'

class BattleBot
  LOCK_PATH = "/tmp/battle-bot.lock"

  def initialize
    @lock_file = File.open(LOCK_PATH, "w")
    unless @lock_file.flock(File::LOCK_EX | File::LOCK_NB)
      puts "[봇][pid=#{Process.pid}] 이미 실행 중(락). 종료."
      exit 0
    end

    @seen_notification_ids = Set.new

    @base_url = ENV['MASTODON_BASE_URL']
    @access_token = ENV['ACCESS_TOKEN']

    unless @base_url && @access_token
      puts "[봇][pid=#{Process.pid}] 환경 변수 누락: MASTODON_BASE_URL/ACCESS_TOKEN 확인"
      exit 1
    end

    @sheet_manager = SheetManager.new
    @mastodon_client = ::MastodonClient.new(@base_url, @access_token)
    @command_parser = CommandParser.new(@mastodon_client, @sheet_manager)
    @battle_timer = BattleTimer.new(@mastodon_client, @sheet_manager)

    puts "[봇][pid=#{Process.pid}] 초기화 완료"
  end

  def start
    puts "[봇][pid=#{Process.pid}] 시작..."
    
    # 전투 타이머 시작
    @battle_timer.start

    @mastodon_client.stream(limit: 20, interval: 2, dismiss: false) do |notification|
      type = (notification["type"] || notification[:type]).to_s
      next unless type == "mention"

      nid = (notification["id"] || notification[:id]).to_s
      next if nid.empty?

      if @seen_notification_ids.include?(nid)
        next
      end
      @seen_notification_ids.add(nid)

      status = notification["status"] || notification[:status]
      next unless status

      account = status["account"] || status[:account]
      sender_id = (account["acct"] || account[:acct]).to_s

      content = (status["content"] || status[:content]).to_s
      clean_content = content.gsub(/<[^>]+>/, '').strip

      puts "[봇][pid=#{Process.pid}] 멘션: #{sender_id} - #{clean_content}"

      begin
        @command_parser.parse_and_execute(clean_content, status, sender_id)
      rescue => e
        puts "[봇][pid=#{Process.pid}] 명령 처리 오류: #{e.message}"
        puts e.backtrace.first(5)
      end
    end
  rescue Interrupt
    puts "\n[봇][pid=#{Process.pid}] Ctrl+C로 종료 시그널 받음"
    @battle_timer.stop
  rescue => e
    puts "[봇][pid=#{Process.pid}] 에러: #{e.message}"
    puts e.backtrace.first(10)
    @battle_timer.stop
  end
end

if __FILE__ == $0
  bot = BattleBot.new
  bot.start
end
