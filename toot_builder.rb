class TootBuilder
  MAX_LENGTH = 490

  def initialize(round, turn, log)
    @round = round
    @turn  = turn
    @log   = log
  end

  def build
    team = @turn == 1 ? '선공' : '후공'
    header = "[#{@round}라운드] #{team}팀 행동 정산"

    toots = []

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

    unless @log[:defense].empty?
      chunk = "▷ 방어"
      @log[:defense].each do |line|
        if (chunk + "\n" + line).length > MAX_LENGTH
          toots << chunk
          chunk = "▷ 방어(계속)\n" + line
        else
          chunk += "\n" + line
        end
      end
      toots << chunk
    end

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
