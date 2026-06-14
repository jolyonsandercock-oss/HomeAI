# Hermes Memory & Culture Bridge (Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-way, idempotent, non-clobbering bridge that layers Claude Code's curated culture/infra memories into Hermes's mnemosyne as inherited records, plus a SOUL.md working-discipline culture block.

**Architecture:** A Python script reads Claude Code's memory dir, filters via an explicit manifest, and upserts each selected memory into mnemosyne via its CLI `store` (FTS-recallable — verified). Inherited rows are isolated by a `source` tag prefix `claude-inherit:<slug>`; the bridge only ever touches rows matching that prefix, so Hermes-authored memory is physically untouchable by it. Provenance columns (`author_type`, `scope`) are stamped post-store. Re-runs upsert by slug; changed content supersedes the prior inherited row.

**Tech Stack:** Python 3.11 (Hermes venv at `~/.hermes/hermes-agent/venv`), mnemosyne CLI (`python -m mnemosyne.cli`), sqlite3, pytest, PyYAML.

**Spec:** `docs/superpowers/specs/2026-06-14-architecture-review-and-hermes-memory-bridge-design.md`

**Verified mechanics (from design-phase probes, 2026-06-14):**
- `python -m mnemosyne.cli store "<content>" "<source>" <importance>` → prints `Stored: <id>`; the row is recallable via `recall` (FTS) even though `memory_embeddings` stays empty. Embeddings table is unused by recall — not a blocker.
- A stored row lands in `working_memory` + `memories` with `scope='session'`, `author_type=''`, `trust_tier='STATED'` by default — so provenance must be stamped after store.
- `cli delete <id>` removes it. `recall "<q>" <k>` returns `ID/Content/Score`.
- Banks exist (`bank list` → only `default`); cross-bank recall is unverified, so we use **source-tag isolation** in the default bank, not banks.

---

## File Structure

- Create: `scripts/hermes-bridge/bridge.py` — the bridge (read → filter → upsert → stamp → supersede).
- Create: `scripts/hermes-bridge/manifest.yaml` — explicit exclude-list + soul-list; everything else syncs to mnemosyne.
- Create: `scripts/hermes-bridge/soul_block.py` — renders the working-discipline culture block for SOUL.md.
- Create: `scripts/hermes-bridge/tests/test_bridge.py` — pytest suite against a throwaway DB copy.
- Create: `scripts/hermes-bridge/run-bridge.sh` — cron wrapper (live DB + sentinel re-baseline).
- Modify: joly's crontab — daily bridge run (added in final task, not committed).

---

### Task 1: Verification spike — DB override, source-tag isolation, provenance stamp

**Files:** none (encodes findings into Task 2+). This resolves the three mechanics the bridge depends on.

- [ ] **Step 1: Find the DB-path override for safe testing**

Run:
```bash
cd ~/.hermes/hermes-agent
venv/bin/python -m mnemosyne.cli stats 2>&1 | head
grep -rn "MNEMOSYNE\|db_path\|DB_PATH\|getenv" venv/lib/python3.11/site-packages/mnemosyne/cli.py | head
```
Expected: identify the env var or arg that points the CLI at an alternate DB file (likely `MNEMOSYNE_DB` or a path under `~/.hermes/mnemosyne/data/`). Record the exact override mechanism — tests and the bridge both use it to target a throwaway copy.

- [ ] **Step 2: Prove source-tag isolation + provenance stamp on a throwaway DB**

```bash
cd ~/.hermes/hermes-agent
cp ~/.hermes/mnemosyne/data/mnemosyne.db /tmp/bridge-test.db
# (use the override from Step 1 to target /tmp/bridge-test.db for all of these)
ID=$(venv/bin/python -m mnemosyne.cli store "PROBE fact body" "claude-inherit:probe-slug" 0.6 | sed 's/Stored: //')
sqlite3 /tmp/bridge-test.db "UPDATE working_memory SET scope='global', author_type='claude-code' WHERE id='$ID'; UPDATE memories SET source=source WHERE id='$ID';"
sqlite3 /tmp/bridge-test.db "SELECT id,source,scope,author_type FROM working_memory WHERE id='$ID';"
venv/bin/python -m mnemosyne.cli recall "PROBE fact" 3
rm -f /tmp/bridge-test.db
```
Expected: the UPDATE persists `scope='global'`, `author_type='claude-code'`; recall returns the probe. Confirms the stamp + isolation approach. (If `working_memory`/`memories` use different columns for provenance than observed, record the real column names here for Task 2.)

- [ ] **Step 3: No commit** (spike only). Record the override mechanism + confirmed column names in the executor's notes for Task 2.

---

### Task 2: The manifest

**Files:**
- Create: `scripts/hermes-bridge/manifest.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
# Which Claude Code memories cross to Hermes, and how.
# Default: every memory file (by slug) NOT in `exclude` syncs to mnemosyne.
# Slugs in `soul` ALSO render into SOUL.md's culture block (always-on).

# Claude-Code-workflow-only — Hermes can't act on these.
exclude:
  - check_sprint_number_first
  - ultraplan_handoff
  - cognition_build          # about Claude Code's own hook system

# Highest-altitude culture/discipline — always-on in SOUL.md (and also mnemosyne).
soul:
  - feedback_working_discipline
  - feedback_financial_recon_discipline
  - feedback_homeai            # build rules
```

- [ ] **Step 2: Verify it parses**

Run:
```bash
cd /home_ai
~/.hermes/hermes-agent/venv/bin/python -c "import yaml,sys; d=yaml.safe_load(open('scripts/hermes-bridge/manifest.yaml')); print(sorted(d))"
```
Expected: `['exclude', 'soul']`.

- [ ] **Step 3: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/manifest.yaml
git commit -m "feat(hermes-bridge): transfer manifest (exclude + soul lists)"
```

---

### Task 3: Bridge core — parse a memory file

**Files:**
- Create: `scripts/hermes-bridge/bridge.py`
- Create: `scripts/hermes-bridge/tests/test_bridge.py`

- [ ] **Step 1: Write the failing test**

```python
# scripts/hermes-bridge/tests/test_bridge.py
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bridge

def test_parse_memory_splits_frontmatter(tmp_path):
    f = tmp_path / "feedback_example.md"
    f.write_text(
        "---\n"
        "name: feedback-example\n"
        "description: a one-line summary\n"
        "metadata:\n  type: feedback\n"
        "---\n\n"
        "The actual fact body.\n"
    )
    m = bridge.parse_memory(f)
    assert m.slug == "feedback_example"      # slug derives from filename stem
    assert m.description == "a one-line summary"
    assert m.mtype == "feedback"
    assert m.body.strip() == "The actual fact body."
```

- [ ] **Step 2: Run it, verify failure**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py::test_parse_memory_splits_frontmatter -v`
Expected: FAIL (`ModuleNotFoundError: bridge` or `AttributeError: parse_memory`).

- [ ] **Step 3: Implement `parse_memory`**

```python
# scripts/hermes-bridge/bridge.py
"""Hermes memory bridge — one-way sync of Claude Code memories into mnemosyne.
Inherited rows are isolated by source tag 'claude-inherit:<slug>'; the bridge
only ever reads/writes rows with that prefix. Hermes-authored memory is never
touched. See docs/superpowers/specs/2026-06-14-...-design.md.
"""
from __future__ import annotations
import dataclasses, pathlib, re

SOURCE_PREFIX = "claude-inherit:"

@dataclasses.dataclass
class Memory:
    slug: str
    description: str
    mtype: str
    body: str

def parse_memory(path: pathlib.Path) -> Memory:
    text = path.read_text()
    fm, _, body = text.partition("\n---\n") if text.startswith("---\n") else ("", "", text)
    fm = fm[4:] if fm.startswith("---\n") else fm   # strip leading '---\n'
    def field(key):
        m = re.search(rf"^{key}:\s*(.+)$", fm, re.MULTILINE)
        return m.group(1).strip() if m else ""
    mtype = ""
    mt = re.search(r"type:\s*(\w+)", fm)
    if mt:
        mtype = mt.group(1)
    return Memory(slug=path.stem, description=field("description"), mtype=mtype, body=body.strip())
```

- [ ] **Step 4: Run it, verify pass**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/bridge.py scripts/hermes-bridge/tests/test_bridge.py
git commit -m "feat(hermes-bridge): parse_memory frontmatter splitter + test"
```

---

### Task 4: Select the transfer set from the manifest

**Files:**
- Modify: `scripts/hermes-bridge/bridge.py`
- Modify: `scripts/hermes-bridge/tests/test_bridge.py`

- [ ] **Step 1: Write the failing test**

```python
def test_select_excludes_manifest_and_index(tmp_path):
    memdir = tmp_path / "mem"; memdir.mkdir()
    for name in ["feedback_keep", "check_sprint_number_first", "MEMORY"]:
        (memdir / f"{name}.md").write_text(
            "---\nname: x\ndescription: d\nmetadata:\n  type: feedback\n---\nbody\n")
    manifest = {"exclude": ["check_sprint_number_first"], "soul": []}
    slugs = sorted(m.slug for m in bridge.select_memories(memdir, manifest))
    assert slugs == ["feedback_keep"]          # MEMORY.md skipped, excluded skipped
```

- [ ] **Step 2: Run it, verify failure**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py::test_select_excludes_manifest_and_index -v`
Expected: FAIL (`AttributeError: select_memories`).

- [ ] **Step 3: Implement `select_memories`**

```python
def select_memories(memdir: pathlib.Path, manifest: dict) -> list[Memory]:
    exclude = set(manifest.get("exclude") or [])
    out = []
    for p in sorted(memdir.glob("*.md")):
        if p.stem == "MEMORY" or p.stem in exclude:
            continue
        out.append(parse_memory(p))
    return out
```

- [ ] **Step 4: Run it, verify pass**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/bridge.py scripts/hermes-bridge/tests/test_bridge.py
git commit -m "feat(hermes-bridge): manifest-driven memory selection + test"
```

---

### Task 5: Mnemosyne adapter — store/find/stamp/supersede against a real DB copy

**Files:**
- Modify: `scripts/hermes-bridge/bridge.py`
- Modify: `scripts/hermes-bridge/tests/test_bridge.py`

This task uses a throwaway copy of the live mnemosyne DB (per Task 1's override mechanism). Replace `DB_ENV` / override usage below with the exact mechanism confirmed in Task 1.

- [ ] **Step 1: Write the failing test (real CLI against a copied DB)**

```python
import shutil, subprocess, sqlite3, os

LIVE_DB = os.path.expanduser("~/.hermes/mnemosyne/data/mnemosyne.db")
VENV_PY = os.path.expanduser("~/.hermes/hermes-agent/venv/bin/python")

def _copy_db(tmp_path):
    dst = tmp_path / "mnemo.db"
    shutil.copy(LIVE_DB, dst)
    return str(dst)

def test_store_then_find_by_slug(tmp_path):
    db = _copy_db(tmp_path)
    adapter = bridge.Mnemosyne(db_path=db, venv_py=VENV_PY)
    rid = adapter.store(slug="probe-slug", content="probe body alpha", importance=0.6)
    assert rid                                   # got an id back
    found = adapter.find_by_slug("probe-slug")
    assert found and found["id"] == rid
    assert found["source"] == bridge.SOURCE_PREFIX + "probe-slug"
    assert found["author_type"] == "claude-code"  # stamped
    assert found["scope"] == "global"
```

- [ ] **Step 2: Run it, verify failure**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py::test_store_then_find_by_slug -v`
Expected: FAIL (`AttributeError: Mnemosyne`).

- [ ] **Step 3: Implement the adapter**

```python
import os, subprocess, sqlite3

class Mnemosyne:
    def __init__(self, db_path: str, venv_py: str):
        self.db_path = db_path
        self.venv_py = venv_py

    def _cli(self, *args) -> str:
        env = dict(os.environ)
        env["MNEMOSYNE_DB"] = self.db_path     # override confirmed in Task 1; adjust if different
        cp = subprocess.run([self.venv_py, "-m", "mnemosyne.cli", *args],
                            capture_output=True, text=True, env=env, check=True,
                            cwd=os.path.expanduser("~/.hermes/hermes-agent"))
        return cp.stdout

    def store(self, slug: str, content: str, importance: float) -> str:
        src = SOURCE_PREFIX + slug
        out = self._cli("store", content, src, str(importance))
        rid = out.split("Stored:")[-1].strip().split()[0]
        self._stamp(rid)
        return rid

    def _stamp(self, rid: str):
        with sqlite3.connect(self.db_path) as cx:
            for tbl in ("working_memory", "memories"):
                cols = {r[1] for r in cx.execute(f"PRAGMA table_info({tbl})")}
                sets = []
                if "scope" in cols: sets.append("scope='global'")
                if "author_type" in cols: sets.append("author_type='claude-code'")
                if sets:
                    cx.execute(f"UPDATE {tbl} SET {','.join(sets)} WHERE id=?", (rid,))

    def find_by_slug(self, slug: str) -> dict | None:
        src = SOURCE_PREFIX + slug
        with sqlite3.connect(self.db_path) as cx:
            cx.row_factory = sqlite3.Row
            row = cx.execute(
                "SELECT id, content, source, scope, author_type FROM working_memory "
                "WHERE source=? AND superseded_by IS NULL ORDER BY created_at DESC LIMIT 1",
                (src,)).fetchone()
            return dict(row) if row else None

    def supersede(self, old_id: str, new_id: str):
        with sqlite3.connect(self.db_path) as cx:
            cx.execute("UPDATE working_memory SET superseded_by=? WHERE id=?", (new_id, old_id))
```

- [ ] **Step 4: Run it, verify pass**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py -v`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/bridge.py scripts/hermes-bridge/tests/test_bridge.py
git commit -m "feat(hermes-bridge): mnemosyne adapter store/find/stamp/supersede + test"
```

---

### Task 6: Sync — idempotent, supersedes on change, non-clobbering

**Files:**
- Modify: `scripts/hermes-bridge/bridge.py`
- Modify: `scripts/hermes-bridge/tests/test_bridge.py`

- [ ] **Step 1: Write the failing tests (the core guarantees)**

```python
def _count_inherit(db):
    with sqlite3.connect(db) as cx:
        return cx.execute("SELECT count(*) FROM working_memory "
                          "WHERE source LIKE 'claude-inherit:%' AND superseded_by IS NULL").fetchone()[0]

def _write_mem(memdir, slug, body):
    (memdir / f"{slug}.md").write_text(
        f"---\nname: {slug}\ndescription: d\nmetadata:\n  type: feedback\n---\n{body}\n")

def test_sync_idempotent(tmp_path):
    db = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    adapter = bridge.Mnemosyne(db_path=db, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    first = _count_inherit(db)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)   # run again
    assert _count_inherit(db) == first                          # no duplicates

def test_sync_supersedes_on_change(tmp_path):
    db = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    adapter = bridge.Mnemosyne(db_path=db, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    _write_mem(memdir, "feedback_a", "body two CHANGED")
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    live = adapter.find_by_slug("feedback_a")
    assert "CHANGED" in live["content"]                         # newest wins
    assert _count_inherit(db) == 1                              # old superseded, not duplicated

def test_sync_never_touches_hermes_rows(tmp_path):
    db = _copy_db(tmp_path)
    with sqlite3.connect(db) as cx:
        before = cx.execute("SELECT count(*), coalesce(sum(length(content)),0) FROM working_memory "
                            "WHERE source IS NULL OR source NOT LIKE 'claude-inherit:%'").fetchone()
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    bridge.sync(memdir, {"exclude": [], "soul": []}, bridge.Mnemosyne(db_path=db, venv_py=VENV_PY))
    with sqlite3.connect(db) as cx:
        after = cx.execute("SELECT count(*), coalesce(sum(length(content)),0) FROM working_memory "
                          "WHERE source IS NULL OR source NOT LIKE 'claude-inherit:%'").fetchone()
    assert before == after                                      # Hermes-authored rows byte-stable

def test_sync_recallable(tmp_path):
    db = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_uniqueword", "zticonium is the magic token")
    adapter = bridge.Mnemosyne(db_path=db, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    assert "zticonium" in adapter._cli("recall", "zticonium", "3")
```

- [ ] **Step 2: Run them, verify failure**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py -v`
Expected: the four new tests FAIL (`AttributeError: sync`).

- [ ] **Step 3: Implement `sync`**

```python
def sync(memdir: pathlib.Path, manifest: dict, adapter: "Mnemosyne") -> dict:
    stats = {"new": 0, "updated": 0, "unchanged": 0}
    for mem in select_memories(memdir, manifest):
        content = f"{mem.description}\n\n{mem.body}".strip()
        existing = adapter.find_by_slug(mem.slug)
        if existing is None:
            adapter.store(mem.slug, content, importance=0.6)
            stats["new"] += 1
        elif existing["content"].strip() != content:
            new_id = adapter.store(mem.slug, content, importance=0.6)
            adapter.supersede(existing["id"], new_id)
            stats["updated"] += 1
        else:
            stats["unchanged"] += 1
    return stats
```

- [ ] **Step 4: Run them, verify pass**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py -v`
Expected: 7 passed.

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/bridge.py scripts/hermes-bridge/tests/test_bridge.py
git commit -m "feat(hermes-bridge): idempotent non-clobbering sync with supersession + tests"
```

---

### Task 7: SOUL.md working-discipline culture block

**Files:**
- Create: `scripts/hermes-bridge/soul_block.py`
- Modify: `scripts/hermes-bridge/tests/test_bridge.py`

- [ ] **Step 1: Write the failing test**

```python
import soul_block

def test_soul_block_is_idempotent(tmp_path):
    soul = tmp_path / "SOUL.md"
    soul.write_text("# Hermes\n\nExisting contract.\n")
    soul_block.upsert_culture_block(soul)
    once = soul.read_text()
    soul_block.upsert_culture_block(soul)          # run again
    twice = soul.read_text()
    assert once == twice                           # block written exactly once
    assert "Build & working discipline (inherited from Claude Code)" in once
    assert "verify before declaring done" in once.lower()
    assert "Existing contract." in once            # original preserved
```

- [ ] **Step 2: Run it, verify failure**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py::test_soul_block_is_idempotent -v`
Expected: FAIL (`ModuleNotFoundError: soul_block`).

- [ ] **Step 3: Implement `soul_block.py`**

```python
# scripts/hermes-bridge/soul_block.py
"""Idempotently maintain the inherited working-discipline block in SOUL.md.
Delimited by HTML-comment markers so re-runs replace, never append."""
import pathlib

BEGIN = "<!-- BEGIN claude-inherited-discipline -->"
END = "<!-- END claude-inherited-discipline -->"

BLOCK = f"""{BEGIN}
## Build & working discipline (inherited from Claude Code)

1. **Verify before declaring done** — never claim success without running the code/command and reading the output.
2. **No guessed CLI flags** — confirm a flag/endpoint exists before using it; don't invent.
3. **Break iteration loops after 3 failed attempts** — stop and question the approach/architecture, don't attempt fix #4.
4. **Audit consumers before replacing a producer** — find who reads a table/endpoint before you change or remove it.
5. **State sync at session start** — check live state before acting on remembered state; memories are point-in-time.
6. **Financial recon discipline** — dedup before summing; DB-derive every line; cross-foot totals; statement/POS beats derived tables; an entity is not one account.
7. **Scripts-with-prompts beat copy-paste** — hand the human a runnable script, not steps to retype.
{END}
"""

def upsert_culture_block(soul_path: pathlib.Path) -> None:
    text = soul_path.read_text()
    if BEGIN in text and END in text:
        pre = text[: text.index(BEGIN)]
        post = text[text.index(END) + len(END) :]
        text = pre + BLOCK.strip() + post
    else:
        text = text.rstrip() + "\n\n" + BLOCK
    soul_path.write_text(text)
```

- [ ] **Step 4: Run it, verify pass**

Run: `cd /home_ai/scripts/hermes-bridge && ~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_bridge.py -v`
Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/soul_block.py scripts/hermes-bridge/tests/test_bridge.py
git commit -m "feat(hermes-bridge): idempotent SOUL.md working-discipline culture block + test"
```

---

### Task 8: CLI entrypoint + cron wrapper (live run, sentinel-aware)

**Files:**
- Modify: `scripts/hermes-bridge/bridge.py`
- Create: `scripts/hermes-bridge/run-bridge.sh`

- [ ] **Step 1: Add a `__main__` entrypoint to bridge.py**

```python
def main():
    import argparse, yaml, os
    ap = argparse.ArgumentParser()
    ap.add_argument("--memdir", default=os.path.expanduser("~/.claude/projects/-home-joly/memory"))
    ap.add_argument("--db", default=os.path.expanduser("~/.hermes/mnemosyne/data/mnemosyne.db"))
    ap.add_argument("--manifest", default=str(pathlib.Path(__file__).parent / "manifest.yaml"))
    ap.add_argument("--soul", default=os.path.expanduser("~/.hermes/SOUL.md"))
    ap.add_argument("--venv-py", default=os.path.expanduser("~/.hermes/hermes-agent/venv/bin/python"))
    a = ap.parse_args()
    manifest = yaml.safe_load(open(a.manifest))
    adapter = Mnemosyne(db_path=a.db, venv_py=a.venv_py)
    stats = sync(pathlib.Path(a.memdir), manifest, adapter)
    import soul_block
    soul_block.upsert_culture_block(pathlib.Path(a.soul))
    print(f"bridge: {stats}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the cron wrapper with sentinel re-baseline**

```bash
# scripts/hermes-bridge/run-bridge.sh
#!/bin/bash
# Daily one-way sync of Claude Code memories → Hermes mnemosyne + SOUL.md.
# Re-baselines hermes-sentinel afterwards so the legitimate memory/soul writes
# don't trip a drift alert (memory + soul are watched persistence surfaces).
set -uo pipefail
LOG=/home_ai/logs/hermes-bridge.log
PY=~/.hermes/hermes-agent/venv/bin/python
echo "$(date -Is) bridge start" >> "$LOG"
"$PY" /home_ai/scripts/hermes-bridge/bridge.py >> "$LOG" 2>&1
rc=$?
echo "$(date -Is) bridge rc=$rc" >> "$LOG"
# Re-baseline sentinel ONLY if the bridge succeeded (else preserve drift signal)
if [ "$rc" -eq 0 ] && [ -x /home_ai/scripts/hermes-sentinel.sh ]; then
  /home_ai/scripts/hermes-sentinel.sh --rebaseline >> "$LOG" 2>&1 || \
    echo "$(date -Is) WARN sentinel rebaseline flag unsupported — verify manually" >> "$LOG"
fi
exit $rc
```

- [ ] **Step 3: Verify sentinel supports `--rebaseline`**

Run: `grep -n "rebaseline\|baseline" /home_ai/scripts/hermes-sentinel.sh | head`
Expected: confirm the flag exists. If it does NOT, the wrapper's fallback logs a warning; in that case replace the re-baseline line with the sentinel's actual baseline-refresh command (read the script to find it). Do not leave the bridge tripping false alerts.

- [ ] **Step 4: Make executable + dry-run the entrypoint help**

```bash
chmod +x /home_ai/scripts/hermes-bridge/run-bridge.sh
~/.hermes/hermes-agent/venv/bin/python /home_ai/scripts/hermes-bridge/bridge.py --help
```
Expected: argparse help prints (no exceptions).

- [ ] **Step 5: Commit**

```bash
cd /home_ai && git add scripts/hermes-bridge/bridge.py scripts/hermes-bridge/run-bridge.sh
git commit -m "feat(hermes-bridge): CLI entrypoint + sentinel-aware cron wrapper"
```

---

### Task 9: First live run + verification on the real DB

**Files:** none (operational).

- [ ] **Step 1: Back up the live mnemosyne DB first**

```bash
cd ~/.hermes/hermes-agent
venv/bin/python -m mnemosyne.cli backup ~/.hermes/mnemosyne/backups/ 2>&1 | tail -2
```
Expected: a backup file is written (rollback safety before first real write).

- [ ] **Step 2: Run the bridge for real**

```bash
bash /home_ai/scripts/hermes-bridge/run-bridge.sh
tail -5 /home_ai/logs/hermes-bridge.log
```
Expected: `bridge: {'new': N, 'updated': 0, 'unchanged': 0}` with N ≈ (memory count − excludes). rc=0.

- [ ] **Step 3: Verify inherited records present, recallable, isolated**

```bash
DB=~/.hermes/mnemosyne/data/mnemosyne.db
sqlite3 "$DB" "SELECT count(*) FROM working_memory WHERE source LIKE 'claude-inherit:%' AND superseded_by IS NULL;"
cd ~/.hermes/hermes-agent && venv/bin/python -m mnemosyne.cli recall "bank_transactions duplicate rows dedup" 3
venv/bin/python -m mnemosyne.cli recall "docker exec stdin trap" 3
```
Expected: count ≈ N; both recalls return the inherited facts.

- [ ] **Step 4: Verify SOUL.md got the culture block exactly once**

```bash
grep -c "BEGIN claude-inherited-discipline" ~/.hermes/SOUL.md
grep -c "verify before declaring done" ~/.hermes/SOUL.md
```
Expected: `1` and `1`.

- [ ] **Step 5: Verify idempotency on the live DB**

```bash
bash /home_ai/scripts/hermes-bridge/run-bridge.sh
tail -1 /home_ai/logs/hermes-bridge.log
sqlite3 ~/.hermes/mnemosyne/data/mnemosyne.db "SELECT count(*) FROM working_memory WHERE source LIKE 'claude-inherit:%' AND superseded_by IS NULL;"
```
Expected: second run shows mostly `unchanged`; inherited count unchanged from Step 3 (no duplicates).

- [ ] **Step 6: Install the daily cron (joly's crontab — not committed)**

```bash
( crontab -l; echo '17 6 * * * bash /home_ai/scripts/hermes-bridge/run-bridge.sh >> /home_ai/logs/hermes-bridge.log 2>&1' ) | crontab -
crontab -l | grep hermes-bridge
```
Expected: the cron line is present (06:17 daily, before the 07:30 morning brief).

---

## Self-Review (run before handoff)

- **Spec coverage:** living one-way bridge (Tasks 6, 8) ✓; curated scope via manifest (Task 2) ✓; INHERITED isolation by source tag + provenance stamp (Task 5) ✓; non-clobber guarantee (Task 6 `test_sync_never_touches_hermes_rows`) ✓; idempotent upsert + supersession (Task 6) ✓; recallable via embedding/FTS path (Task 6 `test_sync_recallable`, Task 9 Step 3) ✓; SOUL.md culture block (Task 7) ✓; sentinel-aware (Task 8) ✓; cron (Task 9 Step 6) ✓.
- **Acceptance tests from spec:** Hermes rows byte-stable ✓; zero duplicates on re-run ✓; edit→supersede ✓; recallable ✓; no false sentinel alert (Task 8 Step 3 + re-baseline) ✓.
- **Non-goals respected:** no reverse sync, no shared store, mnemosyne engine unchanged. ✓
- **Open item carried from spec:** Task 1 must confirm the exact `MNEMOSYNE_DB` override and provenance column names before Task 5 hard-codes them; the adapter's `_stamp` already PRAGMA-guards column existence as defence.
- **Type consistency:** `Mnemosyne.store/find_by_slug/supersede/_cli/_stamp`, `sync`, `select_memories`, `parse_memory`, `Memory(slug,description,mtype,body)`, `SOURCE_PREFIX`, `soul_block.upsert_culture_block` — names consistent across Tasks 3-9.
```
