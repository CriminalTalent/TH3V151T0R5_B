# toot_builder.rb
class TootBuilder
  MAX_LENGTH = 1000

  def initialize(round, log)
    @round = round
    @log   = log
  end

  def build
    header = "[#{@round}라운드 결과]"

    sections = []
    sections << "▷ 공격\n" + @log[:attack].join("\n") unless @log[:attack].empty?
    sections << "▷ 반격\n" + @log[:defense].join("\n") unless @log[:defense].empty?
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
