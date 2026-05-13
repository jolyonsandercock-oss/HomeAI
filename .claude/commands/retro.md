---
name: retro
description: End-of-session retrospective — extract learnings and update STATUS.md, memory, and AGENTS.md
---

Answer: What did you learn during this session?

File each learning to the correct location:

1. **Build failures / fixes** → append to `/home_ai/.claude/decisions/issues-fixes-log.md`
2. **Architectural decisions** → create `/home_ai/.claude/decisions/YYYY-MM-DD-[topic].md`
3. **Claude failure modes / repeated mistakes** → new `feedback_*.md` under `/home/joly/.claude/projects/-home-joly/memory/` (and link from `MEMORY.md`)
4. **General project conventions** → AGENTS.md main body (only if non-state, non-obvious, durable)

Then update **STATUS.md** (MANDATORY):

- Update "Last updated" date
- Update "Last completed sprint" / latest sprint reference
- Update "Recently Completed" with this session's work (one line)
- Update any "Pending — Jo's input" items that were resolved
- Update "Known Issues" if any were fixed or added
- Update "Latest migration" if a new V## was applied

Then update the canonical auto-memory at `/home/joly/.claude/projects/-home-joly/memory/project_homeai.md`:

- Current build state line
- Migration list (if any new)
- Cron table (if any added)
- "Next candidates" section

Then update AGENTS.md only if a rule or pointer changed (rare — AGENTS.md should be stable).

Report what was filed and where. **Do not end the session without updating STATUS.md and project_homeai.md.**
