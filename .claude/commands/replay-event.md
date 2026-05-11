---
name: replay-event
description: Replay a dead letter event after fixing the root cause
disable-model-invocation: true
---
Follow the dead letter resolution procedure from SPEC.md Appendix F.
Ask for the event_id to replay, then:
1. Show the current dead_letter row and its error_message
2. Confirm the root cause has been fixed before proceeding
3. Run the replay SQL (UPDATE events SET status='pending', retry_count=0...)
4. Run the resolution SQL (UPDATE dead_letter SET resolved=true...)
5. Monitor n8n for successful processing of replayed event
