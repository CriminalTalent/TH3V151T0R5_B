require 'sinatra'
require 'json'
require_relative 'google_sheets_service'
require_relative 'map_cache'

set :bind, '0.0.0.0'
set :port, 4567
set :public_folder, File.dirname(__FILE__) + '/public'

# Google Sheets 서비스 초기화 (선택적)
SHEET_ID = ENV['GOOGLE_SHEET_ID'] || '1sf6DpuOZXpLVMc8EwJr_gzsUOx_GO2Tp3mgsIQZtkOQ'
CREDENTIALS_PATH = ENV['GOOGLE_CREDENTIALS_PATH'] || 'credentials.json'

# credentials 파일이 있으면 Google Sheets 연동, 없으면 테스트 모드
if File.exist?(CREDENTIALS_PATH)
  service = GoogleSheetsService.new(SHEET_ID, CREDENTIALS_PATH)
  puts "[맵 서버] Google Sheets 연동 활성화"
else
  service = GoogleSheetsService.new
  puts "[맵 서버] 테스트 모드 - Google Sheets 비활성화"
end

before do
  headers 'Access-Control-Allow-Origin' => '*'
end

# 위치 가져오기 (플레이어)
get '/api/players' do
  content_type :json
  begin
    players = service.get_player_positions
    { success: true, players: players }.to_json
  rescue => e
    puts "[에러] /api/players: #{e.message}"
    { success: true, players: [] }.to_json
  end
end

# 타일 세부 조사 정보
get '/api/tile/:name' do
  content_type :json
  name = params[:name]
  
  # map_data.json에서 타일 찾기
  data = MapCache.load
  found_tile = nil
  
  data.each do |floor_code, floor_data|
    if floor_data["grid"]
      floor_data["grid"].each do |coord, tile|
        if tile["name"] == name
          found_tile = tile.merge(coord: coord, floor: floor_code)
          break
        end
      end
    end
    break if found_tile
  end
  
  if found_tile
    { success: true, tile: found_tile }.to_json
  else
    { success: false, error: "Tile '#{name}' not found" }.to_json
  end
end

# 전체 맵 JSON (새 구조 반영)
get '/api/map-json/:floor' do
  content_type :json
  data = MapCache.load
  floor = params[:floor]
  
  if data[floor]
    { success: true, floor: data[floor] }.to_json
  else
    { success: false, error: "Floor '#{floor}' not found" }.to_json
  end
end

# 모든 층 목록
get '/api/floors' do
  content_type :json
  data = MapCache.load
  floors = data.keys.map do |floor_code|
    {
      code: floor_code,
      name: data[floor_code]["name"],
      difficulty: data[floor_code]["difficulty"],
      investigation_type: data[floor_code]["investigation_type"]
    }
  end
  { success: true, floors: floors }.to_json
end

# 활성 탐색 목록 API
get '/api/explorations' do
  content_type :json
  
  begin
    require_relative 'core/coordinate_exploration_system'
    
    explorations = CoordinateExplorationSystem.explorations.values.select do |exp|
      exp[:active] == true
    end
    
    { success: true, explorations: explorations }.to_json
  rescue => e
    puts "[에러] /api/explorations: #{e.message}"
    { success: true, explorations: [] }.to_json
  end
end

# 관리자 저장 API
post '/api/admin/save-map' do
  content_type :json
  
  begin
    new_data = JSON.parse(request.body.read)
    MapCache.save(new_data)
    { success: true, message: "맵 데이터 저장 완료" }.to_json
  rescue JSON::ParserError => e
    status 400
    { success: false, error: "Invalid JSON: #{e.message}" }.to_json
  rescue => e
    status 500
    { success: false, error: "Save failed: #{e.message}" }.to_json
  end
end

# 관리자 대시보드
get '/admin' do
  send_file File.join(settings.public_folder, 'admin_dashboard.html')
end

# 모니터링 페이지
get '/monitor' do
  send_file File.join(settings.public_folder, 'monitor.html')
end

# 실시간 맵
get '/map' do
  send_file File.join(settings.public_folder, 'realtime_map.html')
end

# 층별 맵 (쿼리 파라미터)
get '/map/:floor' do
  send_file File.join(settings.public_folder, 'realtime_map.html')
end

# 루트 - 맵으로 리다이렉트
get '/' do
  redirect '/map'
end

# 서버 상태 체크
get '/api/health' do
  content_type :json
  { 
    success: true, 
    status: "online",
    timestamp: Time.now.to_i,
    floors_count: MapCache.load.keys.size
  }.to_json
end
