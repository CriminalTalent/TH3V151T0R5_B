#!/usr/bin/env ruby
# encoding: UTF-8
#
# 배포 전 실행: ruby preflight_check.rb
#
# 1단계: 디렉토리의 모든 .rb 파일에 `ruby -c` 문법 검사를 돌린다.
#         (지금까지 실제로 봇을 죽인 사고는 전부 이 단계에서 잡힌다)
# 2단계: main.rb를 제외한 각 파일을 개별 프로세스에서 실제로 require해서
#         로드 시점 오류(오타로 인한 NameError, 잘못된 require 경로 등)를 잡는다.
#
# Mastodon/Google Sheets에는 전혀 연결하지 않으므로 안전하게 반복 실행 가능.

require 'open3'

dir = __dir__
rb_files = Dir.glob(File.join(dir, '*.rb')).reject { |f| File.expand_path(f) == File.expand_path(__FILE__) }

if rb_files.empty?
  puts "검사할 .rb 파일이 없습니다: #{dir}"
  exit 1
end

puts "=== 1단계: 문법 검사 (ruby -c) ==="
syntax_ok = true
rb_files.sort.each do |f|
  out, status = Open3.capture2e('ruby', '-c', f)
  if status.success?
    puts "OK   #{File.basename(f)}"
  else
    syntax_ok = false
    puts "FAIL #{File.basename(f)}"
    puts out.split("\n").map { |l| "     #{l}" }.join("\n")
  end
end

unless syntax_ok
  puts "\n[중단] 문법 오류가 있습니다. 위 FAIL 항목을 고친 뒤 다시 실행하세요."
  exit 1
end

puts "\n=== 2단계: 로드 검사 (require) ==="
loadable = rb_files.reject { |f| File.basename(f) == 'main.rb' }
load_ok = true

loadable.sort.each do |f|
  script = <<~RUBY
    begin
      require 'dotenv'
      Dotenv.load(File.join(#{dir.inspect}, '.env'))
    rescue LoadError
    end
    begin
      require #{f.inspect}
      puts 'PREFLIGHT_OK'
    rescue Exception => e
      puts "PREFLIGHT_FAIL: \#{e.class}: \#{e.message}"
      puts e.backtrace.first(5).join("\\n")
    end
  RUBY

  out, _status = Open3.capture2e('ruby', '-I', dir, '-e', script)
  if out.include?('PREFLIGHT_OK')
    puts "OK   #{File.basename(f)}"
  else
    load_ok = false
    puts "FAIL #{File.basename(f)}"
    puts out.split("\n").map { |l| "     #{l}" }.join("\n")
  end
end

if load_ok
  puts "\n[통과] 문법/로드 검사를 모두 통과했습니다."
  puts "(단, 시트 구조나 실제 전투 로직 오류까지는 잡지 못합니다 — 이건 사람이 확인해야 합니다)"
else
  puts "\n[중단] 로드 중 오류가 있습니다. 위 FAIL 항목을 고친 뒤 다시 실행하세요."
  exit 1
end
