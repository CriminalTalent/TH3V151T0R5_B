def handle_movement(username, text, actions, ctx, positions, view_sheet, runner_sheet, creature)
  m = text.to_s.match(/\[이동\/([A-Ga-g][1-8])\]/)
  return false unless m
  
  target_pos = m[1].upcase
  
  if BattleGrid.creature_cells(creature).include?(target_pos)
    return false
  end
  
  (ctx[:positions] ||= {})[username.to_s] = target_pos
  actions[username.to_s] = { type: '이동', target: target_pos }
  
  true
end

def validate_coordinate_attack(cells, session)
  return true if session.id.to_s.empty?
  
  awaiting = sessions.values.select { |s| s.awaiting_boss && s != session }
  awaiting.length <= 1
end

def validate_whole_attack(skill, session)
  return true if skill != '전체공격'
  
  awaiting = sessions.values.select { |s| s.awaiting_boss && s != session }
  awaiting.length <= 1
end
