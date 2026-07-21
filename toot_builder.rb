class TootBuilder
  MAX_LENGTH = 980

  def initialize(round, team_name, is_first, log)
    @round     = round
    @team_name = team_name
    @is_first  = is_first
    @log       = log
  end

  def build
    order  = @is_first ? '선공' : '후공'
    header = "[#{@round}라운드] #{@team_name} (#{order}) 행동 정산"

    sections = []
    sections << "▷ 지원\n" + @log[:support].join("\n") unless @log[:support].empty?
    sections << "▷ 이동\n" + @log[:move].join("\n") unless @log[:move].empty?
    sections << "▷ 공격\n" + @log[:attack].join("\n") unless @log[:attack].empty?
    sections << "▷ 방어\n" + @log[:defense].join("\n") unless @log[:defense].empty?
    sections << "▷ 현황\n" + @log[:result].join("\n") unless @log[:result].empty?

    full_text = header + (sections.empty? ? "" : "\n\n" + sections.join("\n\n"))

    if full_text.length <= MAX_LENGTH
      return [full_text]
    end

    toots = []
    current = header.dup
    sections.each do |sec|
      candidate = current + "\n\n" + sec
      if candidate.length <= MAX_LENGTH
        current = candidate
      else
        toots << current
        current = sec
      end
    end
    toots << current
    toots
  end
end
