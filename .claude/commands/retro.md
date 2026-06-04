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

Then **reconcile `MASTER.md` §1–§3** (the living reference, MANDATORY): move work shipped this session into §1 Completed, demote anything broken/replaced into §3 Degraded/Superseded, refresh §2 Next phases, and bump "Last curated" to today. (§4 commit log auto-appends nightly — leave it.)

Regenerate the capability index (MANDATORY): `python3 /home_ai/scripts/gen-capabilities.py`
(keeps `CAPABILITIES.md` current so the next session can check what exists before building).

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

Finally, **draft the next session's opening prompt** → write (overwrite) `/home_ai/.claude/NEXT-SESSION.md`, ~10 lines max, with: (a) where we left off (1–2 lines), (b) the top 1–3 focus items pulled from `MASTER.md` §2, (c) any open decisions awaiting Jo, (d) anything mid-flight or fragile to watch (e.g. a deploy in progress, a degraded scraper). The aim is the next session opens with context + focus, not a cold read.

Report what was filed and where. **Do not end the session without reconciling MASTER.md §1–§3, updating STATUS.md + project_homeai.md, and writing NEXT-SESSION.md.**
