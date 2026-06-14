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
        return out.split("Stored:")[-1].strip().split()[0]

    def find_by_slug(self, slug: str) -> dict | None:
        src = SOURCE_PREFIX + slug
        with sqlite3.connect(self._db_path()) as cx:
            cx.row_factory = sqlite3.Row
            row = cx.execute(
                "SELECT id, content, source FROM memories "
                "WHERE source=? ORDER BY created_at DESC LIMIT 1",
                (src,)).fetchone()
            return dict(row) if row else None

    def delete(self, mem_id: str):
        self._cli("delete", mem_id)


def sync(memdir: pathlib.Path, manifest: dict, adapter: "Mnemosyne") -> dict:
    stats = {"new": 0, "updated": 0, "unchanged": 0}
    for mem in select_memories(memdir, manifest):
        content = f"{mem.description}\n\n{mem.body}".strip()
        existing = adapter.find_by_slug(mem.slug)
        if existing is None:
            adapter.store(mem.slug, content, importance=0.6)
            stats["new"] += 1
        elif existing["content"].strip() != content:
            adapter.store(mem.slug, content, importance=0.6)
            adapter.delete(existing["id"])
            stats["updated"] += 1
        else:
            stats["unchanged"] += 1
    return stats


def main():
    import argparse, yaml
    ap = argparse.ArgumentParser(description="One-way sync of Claude Code memories into Hermes mnemosyne.")
    ap.add_argument("--memdir", default=os.path.expanduser("~/.claude/projects/-home-joly/memory"))
    ap.add_argument("--data-dir", default=os.path.expanduser("~/.hermes/mnemosyne/data"))
    ap.add_argument("--manifest", default=str(pathlib.Path(__file__).parent / "manifest.yaml"))
    ap.add_argument("--soul", default=os.path.expanduser("~/.hermes/SOUL.md"))
    ap.add_argument("--venv-py", default=os.path.expanduser("~/.hermes/hermes-agent/venv/bin/python"))
    a = ap.parse_args()
    manifest = yaml.safe_load(open(a.manifest))
    adapter = Mnemosyne(data_dir=a.data_dir, venv_py=a.venv_py)
    stats = sync(pathlib.Path(a.memdir), manifest, adapter)
    import soul_block
    soul_block.upsert_culture_block(pathlib.Path(a.soul))
    print(f"bridge: {stats}")


if __name__ == "__main__":
    main()
