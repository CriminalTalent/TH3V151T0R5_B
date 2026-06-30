$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
require 'time'
require 'net/http'
require 'uri'

Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_listener'

RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')

puts "[전투봇] 시작"

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

puts "[전투봇] 초기화 완료 - 공개 타임라인 모니터링"

last_status_id = nil

loop do
  begin
    uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/timelines/public?local=true")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 10
    
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"
    
    res = http.request(req)
    next if res.code != '200'
    
    statuses = JSON.parse(res.body)
    
    statuses.each do |status|
      next if last_status_id && status['id'].to_i <= last_status_id.to_i
      
      content = status['content'].gsub(/<[^>]*>/, '')
      next unless content.include?('[전투시작]')
      
      mentions = status['mentions']
      usernames = mentions.map { |m| "@#{m['acct']}" }.join(" ")
      round = content.match(/\[(\d+)\]/)&.[](1) || "1"
      
      announcement = "[#{round}라운드 시작]\n\n#{usernames}\n\nDM으로 행동을 입력해주세요.\n" \
                     "[공격/(크리쳐이름)]\n[회복/(아군이름)]\n[방어/(아군이름)]\n[이동/(좌표)]\n\n입력 대기: 5분"
      
      listener.post_public(announcement)
      puts "[전투봇] #{round}라운드 시작 알림 송출"
      
      last_status_id = status['id']
    end
    
  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
  end
  
  sleep(10)
end
