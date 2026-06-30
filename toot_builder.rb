# toot_builder.rb

class TootBuilder
  MAX_LENGTH = 1000

  def initialize(round, creature_name, log)
    @round = round
    @creature_name = creature_name
    @log = log
  end

  def build
    header = "[#{@round}라운드] #{@creature_name} 전투 결과"

    sections = []

    add_section(sections, "행동", @log[:actions])
    add_section(sections, "이동", @log[:move])
    add_section(sections, "공격", @log[:attack])
    add_section(sections, "회복", @log[:heal])
    add_section(sections, "방어", @log[:defense])
    add_section(sections, "크리쳐", @log[:creature])
    add_section(sections, "현황", @log[:result])

    text = header

    unless sections.empty?
      text += "\n\n"
      text += sections.join("\n\n")
    end

    split(text)
  end

  private

  def add_section(list, title, contents)
    return if contents.nil?
    return if contents.empty?

    list << "▷ #{title}\n#{contents.join("\n")}"
  end

  def split(text)
    return [text] if text.length <= MAX_LENGTH

    lines = text.split("\n")

    result = []
    current = ""

    lines.each do |line|
      if (current + line + "\n").length > MAX_LENGTH
        result << current.rstrip
        current = ""
      end

      current << line
      current << "\n"
    end

    result << current.rstrip unless current.empty?

    result
  end
end
