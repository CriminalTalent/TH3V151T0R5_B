# 약 92줄의 post_session_thread 함수를 다음으로 변경:

def post_session_thread(session, text, last_post_time)
  dm = ($trigger_sheet.read_visibility != 'public')
  now = Time.now
  sleep_time = POST_INTERVAL_SECONDS - (now - last_post_time)
  sleep(sleep_time) if sleep_time > 0
  
  response = post_battle_thread(text, dm, session.thread_reply_id, session.runner_tags)
  if response && response['id']
    session.mark_thread_id(response['id'])
    session.thread_ids ||= Set.new
    Array(response['all_ids']).each { |id| session.thread_ids.add(id.to_s) }
  end
  [response, Time.now]
end
