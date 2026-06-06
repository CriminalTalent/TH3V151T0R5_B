# core/midnight_damage.rb
# 자정 데미지 시스템 - 매일 자정 모든 사용자 HP -10

require 'rufus-scheduler'

class MidnightDamage
  DAMAGE_AMOUNT = 10

  def initialize(mastodon_client, sheet_manager)
    @client = mastodon_client
    @sheet_manager = sheet_manager
    @scheduler = Rufus::Scheduler.new
  end

  # 스케줄러 시작
  def start
    # 매일 자정(00:00)에 실행
    @scheduler.cron '0 0 * * *' do
      apply_midnight_damage
    end

    puts "[자정 데미지] 스케줄러 시작됨 - 매일 00:00 실행"
  end

  # 스케줄러 중지
  def stop
    @scheduler.shutdown
    puts "[자정 데미지] 스케줄러 중지됨"
  end

  # 자정 데미지 적용
  def apply_midnight_damage
    puts "[자정 데미지] 실행 시작: #{Time.now}"

    unless @sheet_manager.midnight_damage_enabled?
      puts "[자정 데미지] 비활성화 상태 (전투설정!B2 체크 안됨)"
      return
    end

    all_users = @sheet_manager.get_all_users

    if all_users.nil? || all_users.empty?
      puts "[자정 데미지] 사용자가 없습니다."
      return
    end

    affected_users = []
    dead_users = []

    all_users.each do |user|
      user_id = user["아이디"] || user["ID"]
      next unless user_id

      current_hp = (user["HP"] || 0).to_i

      # HP가 0 이하면 스킵
      next if current_hp <= 0

      new_hp = [current_hp - DAMAGE_AMOUNT, 0].max

      # 업데이트
      @sheet_manager.update_user(user_id, { hp: new_hp })

      user_name = user["이름"] || user_id
      max_hp = calculate_max_hp(user)

      if new_hp <= 0
        dead_users << "#{user_name} (0/#{max_hp})"
      else
        affected_users << "#{user_name} (#{new_hp}/#{max_hp})"
      end
    end

    # 공지 메시지 작성 (이모지 없이)
    message = build_announcement_message(affected_users, dead_users)

    # 공지 툿 (reply_status 없이 직접 포스팅)
    post_announcement(message)

    puts "[자정 데미지] 완료: 영향받은 사용자 #{affected_users.length + dead_users.length}명"
  end

  # 수동 실행 (테스트용)
  def apply_now
    apply_midnight_damage
  end

  private

  # 최대 HP 계산
  def calculate_max_hp(user)
    vitality = (user["체력"] || user[:vitality] || 10).to_i
    base_hp = 100
    base_hp + (vitality * 10)
  end

  # 공지 메시지 작성
  def build_announcement_message(affected_users, dead_users)
    message = "━━━━━━━━━━━━━━━━━━\n"
    message += "자정 데미지\n"
    message += "━━━━━━━━━━━━━━━━━━\n\n"
    message += "모든 캐릭터의 체력이 10씩 감소했습니다.\n\n"

    if affected_users.any?
      message += "생존:\n"
      affected_users.each do |user_info|
        message += "- #{user_info}\n"
      end
    end

    if dead_users.any?
      message += "\n사망:\n"
      dead_users.each do |user_info|
        message += "- #{user_info}\n"
      end
    end

    message += "\n━━━━━━━━━━━━━━━━━━"
    message
  end

  # 공지 포스팅 (public 타임라인)
  def post_announcement(message)
    begin
      @client.create_status(message, visibility: 'public')
      puts "[자정 데미지] 공지 포스팅 완료"
    rescue => e
      puts "[자정 데미지] 공지 포스팅 실패: #{e.message}"
    end
  end
end
