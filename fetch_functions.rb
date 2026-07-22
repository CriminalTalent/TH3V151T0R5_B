def fetch_public_statuses
  $listener.public_timeline(local: true, limit: 20)
rescue => e
  puts "[fetch_public_statuses 오류] #{e.class}: #{e.message}"
  []
end

def fetch_conversations
  $listener.conversations(limit: 20)
rescue => e
  puts "[fetch_conversations 오류] #{e.class}: #{e.message}"
  []
end

def fetch_notifications
  $listener.notifications(limit: 20)
rescue => e
  puts "[fetch_notifications 오류] #{e.class}: #{e.message}"
  []
end
