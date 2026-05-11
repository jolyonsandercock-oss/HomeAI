# Home AI · PARA Vault

Per STRETCH §3.x — knowledge base structured by Tiago Forte's PARA method.
Lives alongside (not inside) the code repo so it can be backed up
separately and synced to Obsidian / mobile if desired.

## Structure

| Folder | What lives here |
|---|---|
| `Projects/` | Active, time-bound efforts. One folder per project. Move to Archives when done. |
| `Areas/` | Ongoing responsibilities — Pub, Properties, Family, Personal, Health. Permanent. |
| `Resources/` | Reference material — supplier contacts, tax rules, software licences, recipes. Indexed by topic. |
| `Archives/` | Completed projects + retired notes. Searchable, never deleted. |

## Conventions

- One markdown file per atomic note. Filename is the note title (kebab-case).
- Front-matter optional but if present, use:
  ```
  ---
  type: project | area | resource | archive
  status: active | dormant | done
  tags: [tag1, tag2]
  reviewed: YYYY-MM-DD
  ---
  ```
- Cross-link via `[[note-name]]` style. The Obsidian sync (Phase 3) renders these.

## Why this lives here

Future Workflow H (Dreaming) and the digest pipelines can read from
`/home_ai/.claude/vault/Areas/Pub.md` etc. for context — e.g. supplier
preferences, regulatory deadlines — without paying tokens for the same
context every prompt. Loading from disk = free.

## Initial seeds

- `Areas/Pub.md`
- `Areas/Properties.md`
- `Areas/Family.md`
- `Areas/Personal.md`
- `Resources/Suppliers.md`
- `Resources/Tax-and-VAT.md`

These are stubs Jo fills in over time.
