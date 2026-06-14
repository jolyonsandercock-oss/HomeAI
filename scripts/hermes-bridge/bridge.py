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
