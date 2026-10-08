# battle_items.rb
# encoding: UTF-8
# 전투 중 물약 사용: 소지 여부 확인과 소지품 차감 ('사용자' 시트 A열=ID, D열=아이템)

module BattleItems
  POTION_SKILLS = %w[위겐웰드물약 디터니원액 수상한영약].freeze
  def self.column_letter(index)
    result = ''
    n = index + 1
    while n > 0
      n -= 1
      result.prepend((65 + (n % 26)).chr)
      n /= 26
    end
    result
  end

  # '사용자' 시트 헤더에서 ID/아이템 열 위치를 찾는다. 못 찾으면 A, D 열로 폴백.
  def self.columns(header_row)
    map = {}
    header_row.to_a.each_with_index { |h, i| map[h.to_s.strip] = i }
    [map['ID'] || 0, map['아이템'] || 3]
  end

  def self.norm(text)
    text.to_s.gsub(/\s+/, '')
  end

  def self.potion?(skill_name)
    POTION_SKILLS.include?(norm(skill_name))
  end

  def self.sheet
    $battle_scout_sheet
  end

  def self.acct(value)
    value.to_s.gsub('@', '').strip.downcase
  end

  # 소지 중이면 true, 없으면 false, 확인 불가(시트 없음/오류)면 nil
  def self.owned?(account, skill_name)
    return nil unless sheet
    rows = sheet.read("'사용자'!A:E")
    return nil if rows.empty?
    id_col, item_col = columns(rows[0])
    rows[1..].to_a.each do |row|
      next unless acct(row[id_col]) == acct(account)
      items = row[item_col].to_s.split(',').map(&:strip)
      return items.any? { |i| norm(i) == norm(skill_name) }
    end
    false
  rescue => e
    puts "[BattleItems.owned? 오류] #{e.class}: #{e.message}"
    nil
  end

  # 소지품에서 1개 차감. 성공하면 true
  def self.consume!(account, skill_name)
    return false unless sheet
    rows = sheet.read("'사용자'!A:E")
    return false if rows.empty?
    id_col, item_col = columns(rows[0])
    rows[1..].to_a.each_with_index do |row, i|
      next unless acct(row[id_col]) == acct(account)
      items = row[item_col].to_s.split(',').map(&:strip).reject(&:empty?)
      idx = items.index { |it| norm(it) == norm(skill_name) }
      return false unless idx
      items.delete_at(idx)
      sheet.write("'사용자'!#{column_letter(item_col)}#{i + 2}", [[items.join(',')]])
      return true
    end
    false
  rescue => e
    puts "[BattleItems.consume! 오류] #{e.class}: #{e.message}"
    false
  end

  # 정산 직후 호출: ctx[:potion_used]에 쌓인 물약을 소지품에서 차감
  def self.consume_all!(ctx)
    used = ctx.delete(:potion_used) || []
    used.each do |u|
      ok = consume!(u[:user], u[:skill])
      puts "[전투봇] 물약 차감 #{ok ? '완료' : '실패'}: @#{u[:user]} #{u[:skill]}"
    end
  end
end
