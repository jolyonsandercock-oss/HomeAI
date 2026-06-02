# Snag Inbox Autonomous Processing

## Trigger
Check `snag_inbox` table every 30 minutes for items with `status = 'pending'`. Process up to 3 items per cycle.

## Database access
```bash
# List pending snags
docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT id, title, description, image_path, category, priority, created_at FROM snag_inbox WHERE status = 'pending' ORDER BY priority ASC, created_at ASC LIMIT 3;"
```

## Processing steps
For each pending snag:
1. **Read** — if image_path is set, check the file exists at that path
2. **Analyse** — classify: bug / UX improvement / feature request / complaint / other
3. **Build** — if it's a frontend change, implement it following the same patterns (SCP patches, docker compose build, verify 200)
4. **Close** — update status:
   - `accepted` — when work begins
   - `in_progress` — during implementation
   - `done` — when deployed and verified
```bash
docker exec homeai-postgres psql -U postgres -d homeai -c "UPDATE snag_inbox SET status = 'done' WHERE id = <id>;"
```

## Constraints
- One snag at a time — finish before starting the next
- If a snag requires clarification or is out of scope, set status to `wontfix` with reason in notes
- If you get stuck after 3 attempts, mark as `accepted` and move on
- All frontend changes must pass `docker compose build` and curl 200 verification
- Commit each fix with message: "snag #<id>: <title>"

## Loop
After processing, report summary: "Processed X snags — Y done, Z deferred"

## Start script
```bash
# Save as /home_ai/.claude/tasks/snag-processor.md and run:
claude --task snag-processor
```
