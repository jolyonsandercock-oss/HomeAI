# TODO / FIXME sweep

Generated 2026-05-15T20:37:04+01:00. Read-only.

Every TODO/FIXME/XXX/HACK marker found in scripts/, services/build-dashboard/, services/bot-responder/.
Archived dirs and `__pycache__` excluded.

## Total: 7 markers

### By file

| file | count | examples |
|---|---|---|
| scripts/u88-todo-sweep.sh | 6 | # u88-todo-sweep.sh — find every TODO/FIXME/XXX/HACK marker in code and \| 'TODO|FIXME|XXX|HACK' \| |
| scripts/restore.sh | 1 | TEMP_RESTORE=$(mktemp -d -t homeai-restore-XXXXXX) \|  |

### Full list (first 50)

```
  scripts/u88-todo-sweep.sh:2  # u88-todo-sweep.sh — find every TODO/FIXME/XXX/HACK marker in code and
  scripts/u88-todo-sweep.sh:10  'TODO|FIXME|XXX|HACK' \
  scripts/u88-todo-sweep.sh:16  echo "# TODO / FIXME sweep"
  scripts/u88-todo-sweep.sh:20  echo "Every TODO/FIXME/XXX/HACK marker found in scripts/, services/build-dashboard/, services/bot-re
  scripts/u88-todo-sweep.sh:25  echo "## Result: ✓ no TODOs found"
  scripts/u88-todo-sweep.sh:36  sample=$(grep -m 2 -E 'TODO|FIXME|XXX|HACK' "$file" 2>/dev/null | head -2 | sed 's/^[[:space:]]*//' 
  scripts/restore.sh:57  TEMP_RESTORE=$(mktemp -d -t homeai-restore-XXXXXX)
```
