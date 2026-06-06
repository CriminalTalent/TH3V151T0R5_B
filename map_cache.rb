require 'json'

class MapCache
  FILE_PATH = File.expand_path("map_data.json", __dir__)
  
  def self.load
    return {} unless File.exist?(FILE_PATH)
    
    begin
      JSON.parse(File.read(FILE_PATH))
    rescue JSON::ParserError => e
      puts "⚠️  맵 데이터 파싱 실패: #{e.message}"
      {}
    rescue => e
      puts "⚠️  맵 데이터 로드 실패: #{e.message}"
      {}
    end
  end
  
  def self.save(data)
    File.write(FILE_PATH, JSON.pretty_generate(data))
    puts "✅ 맵 데이터 저장 완료: #{FILE_PATH}"
    true
  rescue => e
    puts "⚠️  맵 데이터 저장 실패: #{e.message}"
    false
  end
end
