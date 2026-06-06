# cron_tasks/midnight_reset.rb
require 'date'

def run_midnight_reset(sheet_manager, mastodon_client)
  puts "[자정 초기화] 시작 - #{Time.now}"

  begin
    users = sheet_manager.all_users
    return if users.empty?

    reset_count = 0
    users.each do |user|
      uid    = user["ID"]
      next unless uid

      max_hp = (user["체력"] || 50).to_i * 10
      cur_hp = (user["HP"] || max_hp).to_i

      if cur_hp < max_hp
        sheet_manager.update_user(uid, { "HP" => max_hp })
        puts "[자정 초기화] #{uid}: HP #{cur_hp}→#{max_hp}"
        reset_count += 1
      end
    end

    puts "[자정 초기화] 완료 - #{reset_count}명 HP 교정"
  rescue => e
    puts "[자정 초기화 오류] #{e.message}"
  end
end
