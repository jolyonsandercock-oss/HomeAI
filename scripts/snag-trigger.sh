#!/bin/bash
# Snag trigger — pings Claude via bot_instructions when pending snags exist
# Runs every 30 min via cron

PENDING=$(docker exec homeai-postgres psql -U postgres -d homeai -t -c "SELECT count(*) FROM snag_inbox WHERE status = 'pending';" 2>/dev/null | tr -d ' ')

if [ "$PENDING" -gt 0 ] 2>/dev/null; then
  # Avoid spamming — only trigger once per hour
  RECENT=$(docker exec homeai-postgres psql -U postgres -d homeai -t -c "SELECT count(*) FROM bot_instructions WHERE raw_subject LIKE 'snag:%' AND received_at > now() - interval '1 hour';" 2>/dev/null | tr -d ' ')
  
  if [ "$RECENT" -eq 0 ] 2>/dev/null; then
    docker exec homeai-postgres psql -U postgres -d homeai -c "INSERT INTO bot_instructions (raw_subject, raw_text, from_user, source, received_at, realm) VALUES ('snag: $PENDING pending items to process', 'Process snag_inbox. See /home_ai/.claude/tasks/snag-processor.md. $PENDING items pending.', 'snag-trigger', 'manual', now(), 'work');" 2>/dev/null
    echo "$(date -Iseconds) Triggered — $PENDING pending snags" >> /home_ai/logs/snag-trigger.log
  fi
fi
