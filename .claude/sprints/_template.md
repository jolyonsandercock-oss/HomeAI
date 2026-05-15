# U?? — <Short title>

**Prereqs**: <what must have shipped first; or "none">

**Realm**: <`owner` | `work` | `family` | `shared` | `cross-cutting (specify per track)`>
  - Required per AGENTS.md rule #0 and SPEC §2.5.
  - If `cross-cutting`, every track below must carry its own `**Realm:**` line.
  - If a new table is created in this sprint, it must take a `realm` column (or be added to the OWNER-only framework-exempt list with a justification comment in the migration).
  - If a new route is added, it must read `app.current_realm` from the auth header.
  - If a new ingest source is added, it must tag realm at row creation by mailbox-of-receipt and treat realm as immutable without an OWNER-credentialled override.

**Remote vs in-person**: <% remote / % in-person, brief reasoning>

**Why this sprint exists**: <2-4 sentences on the load-bearing reason. What breaks if we don't do this. Reference earlier sprints / memory entries with [[link-name]] if relevant.>

## Tracks

### T1 — <name> (~<duration>)

**Realm**: <if sprint-level realm is `cross-cutting`>

**Build**:
- <concrete actions, file paths, table names, migration numbers>

**Acceptance**:
- <verifiable SQL / curl / test command + expected output>

---

### T2 — <name> (~<duration>)

**Realm**: <as above>

**Build**:
- …

**Acceptance**:
- …

---

## What this sprint does NOT do

- <explicitly list out-of-scope items, especially anything that looks adjacent but is being deferred>

## Follow-on sprints

- **U?? — <name>**: <one-liner>
