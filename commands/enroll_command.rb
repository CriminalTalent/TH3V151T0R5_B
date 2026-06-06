# commands/enroll_command.rb
require 'date'

class EnrollCommand
  INITIAL_GALLEON = 20

  def initialize(sheet_manager, mastodon_client, sender, name, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.gsub('@', '')
    @name            = name
    @status          = status
  end

  def execute
    if @sheet_manager.find_user(@sender)
      @mastodon_client.reply(@status, "#{@name} 학생은 이미 입학한 상태입니다.")
      return
    end

    # 사용자 시트 (A~F열)
    @sheet_manager.append('사용자', [
      @sender, @name, INITIAL_GALLEON, "", "", ""
    ])

    # 스탯 시트 (A~J열)
    # A: ID, B: 이름, C: HP, D: 체력, E: 공격력, F: 방어력, G: 속도, H: 기술, I: 행운, J: 행동력
    @sheet_manager.append('스탯', [
      @sender, @name,
      500,  # C: HP (체력 50 × 10)
      50,   # D: 체력
      10,   # E: 공격력
      10,   # F: 방어력
      0,    # G: 속도
      0,    # H: 기술
      5,    # I: 행운
      5     # J: 행동력
    ])

    # 조사상태 시트
    @sheet_manager.append('조사상태', [
      @sender, "없음", "-", "0", "0", "-"
    ])

    @mastodon_client.reply(@status, "#{@name} 학생, 호그와트에 온 걸 환영해요.")

  rescue => e
    puts "[에러] 입학 처리 중 오류: #{e.message}"
    @mastodon_client.reply(@status, "입학 처리 중 오류가 발생했습니다.")
  end
end
