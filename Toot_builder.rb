# 툿 텍스트 생성
# 마스토돈 툿 하나당 500자 제한 고려하여 섹션별로 분리
class TootBuilder
  MAX_LENGTH = 490

  def initialize(round, turn, log)
    @round = round
    @turn  = turn  # 1=선공, 2=후공
    @log   = log
  end

  def build
    team = @turn == 1 ? '선공' : '후공'
    header = "[#{@round}라운드 #{@turn}턴] #{team}팀 행동 정산"

    toots = []

    # 1번 툿: 헤더 + 지원
    t1 = header.dup
    unless @log[:support].empty?
      t1 += "\n\n▷ 지원\n" + @log[:support].join("\n")
    end
    unless @log[:move].empty?
      candidate = t1 + "\n\n▷ 이동\n" + @log[:move].join("\n")
      if candidate.length <= MAX_LENGTH
        t1 = candidate
      else
        toots << t1
        t1 = "▷ 이동\n" + @log[:move].join("\n")
      end
    end
    toots << t1

    # 공격 로그 (길면 분리)
    unless @log[:attack].empty?
      chunk = "▷ 공격"
      @log[:attack].each do |line|
        if (chunk + "\n" + line).length > MAX_LENGTH
          toots << chunk
          chunk = "▷ 공격(계속)\n" + line
        else
          chunk += "\n" + line
        end
      end
      toots << chunk
    end

    # 최종 현황
    unless @log[:result].empty?
      chunk = "▷ 현황"
      @log[:result].each do |line|
        if (chunk + "\n" + line).length > MAX_LENGTH
          toots << chunk
          chunk = "▷ 현황(계속)\n" + line
        else
          chunk += "\n" + line
        end
      end
      toots << chunk
    end

    toots
  end
end
