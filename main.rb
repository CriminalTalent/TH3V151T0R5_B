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

LOCATION_MAP = {
  '스토디시' => 'E7',
  'A' => 'A1', 'B' => 'B1', 'C' => 'C1', 'D' => 'D1',
  'E' => 'E1', 'F' => 'F1', 'G' => 'G1', 'H' => 'H1'
}

puts "[전투봇] 시작"

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

puts "[전투봇] 초기화 완료 - 공개 타임라인 모니터링"

last_status_id = nil
battle_active = false
battle_actions = {}
battle_start_time = nil
battle_round = nil
processed_messages = {}
battle_announced = false
total_runners = 0
runner_tags = ""

loop do
  begin
    # 공개 타임라인 체크
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
      
      if content.include?('[전투시작]') && !battle_active
        mentions = status['mentions']
        usernames = mentions.select { |m| m['acct'] != 'DOWN' }
        total_runners = usernames.size
        
        if total_runners == 0
          listener.post_public("[전투시작] 참여자가 없습니다. 태그를 추가하세요.")
          puts "[전투봇] 태그된 러너 없음"
          last_status_id = status['id']
          next
        end
        
        runner_tags = usernames.map { |m| "@#{m['acct']}" }.join(" ")
        
        battle_active = true
        battle_announced = false
        battle_start_time = Time.now
        battle_round = content.match(/\[(\d+)\]/)&.[](1) || "1"
        battle_actions = {}
        processed_messages = {}
        
        creature_config = creature_sheet.read_creature_config
        creature_name = creature_config[:name] || "크리쳐"
        
        puts "[전투봇] #{battle_round}라운드 시작 - 참여자 #{total_runners}명, 상대: #{creature_name}"
        
        last_status_id = status['id']
      elsif content.include?('[전투종료]')
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        listener.post_public("[전투 강제 종료]")
        puts "[전투봇] 전투 종료"
        last_status_id = status['id']
      end
    end
    
    # 전투 중 DM 체크
    if battle_active
      if !battle_announced
        creature_config = creature_sheet.read_creature_config
        creature_name = creature_config[:name] || "크리쳐"
        
        announcement = "#{runner_tags}\n\n[#{battle_round}라운드] #{creature_name}와의 전투!\n\n" \
                       "───────────────────\n" \
                       "DM으로 행동을 입력해주세요.\n\n" \
                       "형식:\n" \
                       "  [공격/크리쳐]\n" \
                       "  [회복/아이디]\n" \
                       "  [방어/아이디]\n" \
                       "  [이동/좌표]\n\n" \
                       "입력 대기: 5분\n" \
                       "───────────────────"
        
        listener.post_public(announcement)
        battle_announced = true
        puts "[전투봇] #{battle_round}라운드 안내 송출"
      end
      
      conv_uri = URI("#{ENV['MASTODON_BASE_URL']}/api/v1/conversations")
      conv_http = Net::HTTP.new(conv_uri.host, conv_uri.port)
      conv_http.use_ssl = true
      conv_http.read_timeout = 10
      
      conv_req = Net::HTTP::Get.new(conv_uri)
      conv_req['Authorization'] = "Bearer #{ENV['BATTLE_TOKEN']}"
      
      conv_res = conv_http.request(conv_req)
      next if conv_res.code != '200'
      
      conversations = JSON.parse(conv_res.body)
      
      conversations.each do |conv|
        sender = conv['accounts'].first
        next unless sender
        
        username = sender['username']
        next if username == 'DOWN'
        
        if conv['last_status']
          status_id = conv['last_status']['id']
          next if processed_messages[username]
          
          text = conv['last_status']['content'].gsub(/<[^>]*>/, '')
          
          if text.match?(/\[(공격|회복|방어|이동)\/(.*?)\]/)
            match = text.match(/\[(공격|회복|방어|이동)\/(.*?)\]/)
            action_type = match[1]
            action_target = match[2].strip
            
            if action_type == '이동'
              coord = action_target
              coord = LOCATION_MAP[coord] if LOCATION_MAP[coord]
              
              runner_state = runner_sheet.read_runner_state
              runner = runner_state.find { |r| r[:name] == username }
              
              if runner
                runner[:pos] = coord
                runner_sheet.update_runner_state([runner])
                puts "[전투봇] #{username} 이동 → #{coord}"
              end
            end
            
            battle_actions[username] = { type: action_type, target: action_target }
            puts "[전투봇] #{username} → [#{action_type}/#{action_target}]"
            
            listener.send_dm(username, "확인, 대기해주세요.")
            processed_messages[username] = true
            
            # 모든 러너가 입력했으면 전투 진행
            if battle_actions.size >= total_runners
              creature_config = creature_sheet.read_creature_config
              creature_name = creature_config[:name] || "크리쳐"
              
              result = "#{runner_tags}\n\n[#{battle_round}라운드] #{creature_name} 전투 결과\n\n"
              result += "───────────────────\n"
              battle_actions.each do |username, action|
                result += "#{username}: [#{action[:type]}/#{action[:target]}]\n"
              end
              result += "───────────────────"
              
              parent_id = listener.post_public(result)
              sleep(1)
              
              detailed = "#{creature_name} 현재 상태: 건강 100/200\n" \
                         "전투 정산 완료!\n\n" \
                         "[다음 라운드 대기 중...]\n" \
                         "GM의 [전투시작] 명령을 기다리는 중"
              listener.reply_public(parent_id, detailed)
              
              battle_active = false
              puts "[전투봇] 모든 러너 입력 완료 - 전투 진행"
            end
          end
        end
      end
      
      # 5분 경과 체크
      if (Time.now - battle_start_time) >= 300
        creature_config = creature_sheet.read_creature_config
        creature_name = creature_config[:name] || "크리쳐"
        
        result = "#{runner_tags}\n\n[#{battle_round}라운드] #{creature_name} 전투 결과 (시간 초과)\n\n"
        result += "───────────────────\n"
        battle_actions.each do |username, action|
          result += "#{username}: [#{action[:type]}/#{action[:target]}]\n"
        end
        result += "───────────────────"
        
        parent_id = listener.post_public(result)
        sleep(1)
        
        detailed = "#{creature_name} 현재 상태: 건강 100/200\n" \
                   "전투 정산 완료!\n\n" \
                   "[다음 라운드 대기 중...]\n" \
                   "GM의 [전투시작] 명령을 기다리는 중"
        listener.reply_public(parent_id, detailed)
        
        battle_active = false
        battle_actions = {}
        processed_messages = {}
        battle_announced = false
        puts "[전투봇] #{battle_round}라운드 5분 경과 - 자동 정산"
      end
    end
    
  rescue => e
    puts "[전투봇 오류] #{e.class}: #{e.message}"
  end
  
  sleep(10)
end
