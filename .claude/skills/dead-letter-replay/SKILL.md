# Skill: dead-letter-replay
Replay a failed event from the dead letter queue.

## Procedure (from SPEC.md Appendix F)
1. SELECT dl.*, e.* FROM dead_letter dl JOIN events e ON dl.event_id=e.id WHERE dl.resolved=false ORDER BY dl.created_at DESC;
2. Read error_message and payload carefully
3. Fix the root cause FIRST — never replay without fixing
4. Log fix: append to /home_ai/.claude/decisions/issues-fixes-log.md
5. Replay: UPDATE events SET status='pending', retry_count=0, error_message=null WHERE id=[event_id];
6. Resolve: UPDATE dead_letter SET resolved=true, resolved_at=NOW(), resolution_notes='...' WHERE event_id=[event_id];
7. Monitor n8n for successful processing

## Gotchas
- Never replay a flood (>10 dead letters from same pipeline in 60 min) until pipeline is fixed and reactivated
- Always fix root cause before replaying — replaying without fixing just creates another dead letter
