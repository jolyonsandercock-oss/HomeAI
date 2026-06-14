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
        post = text[text.index(END) + len(END):]
        text = pre + BLOCK.strip() + post
    else:
        text = text.rstrip() + "\n\n" + BLOCK
    soul_path.write_text(text)
