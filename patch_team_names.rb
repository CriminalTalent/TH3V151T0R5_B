#!/usr/bin/env ruby
# battle_engine.rb 팀 이름 하드코딩 패치

file_path = 'core/battle_engine.rb'
content = File.read(file_path)

# 팀1 이름 변경
content.gsub!(/팀1:/, '불사조 기사단:')
content.gsub!(/팀1 승리/, '불사조 기사단 승리')
content.gsub!(/팀2:/, '이그드라실:')
content.gsub!(/팀2 승리/, '이그드라실 승리')

# start_2v2 메서드에서 팀 이름 변경
content.gsub!(
  /message \+= "팀전투 시작: #{names\[0\]}, #{names\[1\]} vs #{names\[2\]}, #{names\[3\]}\\n"/,
  'message += "팀전투 시작!\\n"
    message += "불사조 기사단: #{names[0]}, #{names[1]}\\n"
    message += "이그드라실: #{names[2]}, #{names[3]}\\n"'
)

# start_4v4 메서드에서 팀 이름 변경
content.gsub!(
  /message \+= "팀1: #{names\[0\.\.3\]\.join\(', '\)}\\n"/,
  'message += "불사조 기사단: #{names[0..3].join(\', \')}\\n"'
)

content.gsub!(
  /message \+= "팀2: #{names\[4\.\.7\]\.join\(', '\)}\\n"/,
  'message += "이그드라실: #{names[4..7].join(\', \')}\\n"'
)

File.write(file_path, content)
puts "battle_engine.rb 팀 이름 패치 완료"
