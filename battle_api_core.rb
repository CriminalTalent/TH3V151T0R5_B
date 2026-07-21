def post_battle_thread(text, dm = false, reply_to_id = nil, runner_tags = '')
  visibility = dm ? 'direct' : 'public'
  parts = text.split("\n---SPLIT---\n")
  
  thread_ids = []
  parent_id = reply_to_id
  
  parts.each_with_index do |part, idx|
    toot_text = part
    if idx > 0 && !runner_tags.empty?
      toot_text = "#{runner_tags}\n\n#{part}"
    end
    
    response = listener.post_status(
      toot_text,
      reply_to_id: parent_id,
      visibility: visibility
    )
    
    if response && response['id']
      thread_ids << response['id']
      parent_id = response['id']
    else
      return nil
    end
  end
  
  thread_ids.length > 0 ? { 'id' => thread_ids.last, 'all_ids' => thread_ids } : nil
rescue => e
  puts "[post_battle_thread 오류] #{e.class}: #{e.message}"
  nil
end

def select_auto_skill(creature, creature_sheet)
  return nil unless creature
  
  begin
    rows = creature_sheet.read_range('보스스킬', 'A:Z')
    return nil if rows.empty?
    
    available = []
    
    rows[1..].each do |row|
      skill_name = row[0].to_s.strip
      next if skill_name.empty?
      
      category = row[5].to_s.strip
      priority = row[6].to_i
      
      available << {
        name: skill_name,
        category: category,
        priority: priority
      }
    end
    
    return nil if available.empty?
    
    priority_map = {
      '필수' => 1,
      '생존' => 2,
      '범위' => 3,
      '단일' => 4,
      '기본공격' => 5
    }
    
    available.sort_by do |skill|
      cat_priority = priority_map[skill[:category]] || 99
      [cat_priority, -skill[:priority]]
    end.first[:name]
  rescue => e
    puts "[select_auto_skill 오류] #{e.class}: #{e.message}"
    nil
  end
end
