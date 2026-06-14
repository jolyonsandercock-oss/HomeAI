"""Hermes memory bridge — one-way sync of Claude Code memories into mnemosyne.
Inherited rows are isolated by source tag 'claude-inherit:<slug>'; the bridge
only ever reads/writes rows with that prefix. Hermes-authored memory is never
touched. See docs/superpowers/specs/2026-06-14-...-design.md.
"""
from __future__ import annotations
import dataclasses, pathlib, re, os, subprocess, sqlite3

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


def select_memories(memdir: pathlib.Path, manifest: dict) -> list[Memory]:
    exclude = set(manifest.get("exclude") or [])
    out = []
    for p in sorted(memdir.glob("*.md")):
        if p.stem == "MEMORY" or p.stem in exclude:
            continue
        out.append(parse_memory(p))
    return out


class Mnemosyne:
    def __init__(self, data_dir: str, venv_py: str):
        self.data_dir = data_dir
        self.venv_py = venv_py

    def _db_path(self) -> str:
        return os.path.join(self.data_dir, "mnemosyne.db")

    def _cli(self, *args) -> str:
        env = dict(os.environ)
        env["MNEMOSYNE_DATA_DIR"] = self.data_dir
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
        with sqlite3.connect(self._db_path()) as cx:
            for tbl in ("working_memory", "memories"):
                cols = {r[1] for r in cx.execute(f"PRAGMA table_info({tbl})")}
                sets = []
                if "scope" in cols: sets.append("scope='global'")
                if "author_type" in cols: sets.append("author_type='claude-code'")
                if sets:
                    cx.execute(f"UPDATE {tbl} SET {','.join(sets)} WHERE id=?", (rid,))

    def find_by_slug(self, slug: str) -> dict | None:
        src = SOURCE_PREFIX + slug
        with sqlite3.connect(self._db_path()) as cx:
            cx.row_factory = sqlite3.Row
            row = cx.execute(
                "SELECT id, content, source, scope, author_type FROM working_memory "
                "WHERE source=? AND superseded_by IS NULL ORDER BY created_at DESC LIMIT 1",
                (src,)).fetchone()
            return dict(row) if row else None

    def supersede(self, old_id: str, new_id: str):
        with sqlite3.connect(self._db_path()) as cx:
            cx.execute("UPDATE working_memory SET superseded_by=? WHERE id=?", (new_id, old_id))
