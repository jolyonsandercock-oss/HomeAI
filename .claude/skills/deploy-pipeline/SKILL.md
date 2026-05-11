# Skill: deploy-pipeline
Deploy or update an n8n pipeline workflow.

## Steps
1. Export current workflow JSON from n8n UI (if updating)
2. Save to /home_ai/.claude/n8n-exports/[workflow-name].json
3. Apply changes and import via n8n UI
4. Test with a synthetic event
5. Confirm no dead letters within 5 minutes

## Gotchas
- Always export before modifying — n8n has no built-in undo
- Test idempotency: run the same event twice, confirm single DB row
