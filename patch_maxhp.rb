#!/usr/bin/env ruby
# encoding: UTF-8
path = ARGV[0] or abort "사용법: ruby patch_maxhp.rb sheet_manager.rb"
abort "파일을 찾을 수 없습니다: #{path}" unless File.exist?(path)
src = File.read(path)
raw = DATA.read
blocks = raw.split(/^===PATCH \d+===\n/).reject(&:empty?)
patches = blocks.map do |block|
  parts = block.split(/^---NEW---\n/, 2)
  abort "패치 블록 형식 오류" if parts.size != 2
  old = parts[0].sub(/\A---OLD---\n/, '')
  new = parts[1]
  [old.chomp("\n"), new.chomp("\n")]
end
patches.each_with_index do |(old, new), i|
  count = src.scan(old).size
  if count != 1
    puts "── 패치 #{i + 1} 실패: 대상 문자열이 #{count}번 발견됨 (1번이어야 함) ──"
    puts old
    abort "중단."
  end
  src = src.sub(old, new)
  puts "패치 #{i + 1} 적용 완료"
end
File.write(path, src)
puts "총 #{patches.size}건 패치 완료 -> #{path}"
__END__
===PATCH 1===
---OLD---
        hp_raw = row[4].to_s.strip
        hp = hp_raw.match?(/\A-?\d+\z/) ? [hp_raw.to_i, 0].max : 50
        {
          name:         id,
          id:           id,
          display_name: row[1].to_s.strip,
          house:        row[2].to_s.strip,
          passive:      row[3].to_s.strip,
          hp:           hp,
          max_hp:       hp,
          dur:          row[5].to_i,
---NEW---
        hp_raw = row[4].to_s.strip
        hp = hp_raw.match?(/\A-?\d+\z/) ? [hp_raw.to_i, 0].max : 50
        max_hp_raw = row[10].to_s.strip
        max_hp = max_hp_raw.match?(/\A-?\d+\z/) ? [max_hp_raw.to_i, 0].max : hp
        {
          name:         id,
          id:           id,
          display_name: row[1].to_s.strip,
          house:        row[2].to_s.strip,
          passive:      row[3].to_s.strip,
          hp:           hp,
          max_hp:       max_hp,
          dur:          row[5].to_i,
