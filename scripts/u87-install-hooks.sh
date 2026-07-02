#!/usr/bin/env bash
# u87-install-hooks.sh — install pre-commit hook that entropy-scans staged
# files for accidental secret leaks. Idempotent.

set -euo pipefail

HOOK=/home_ai/.git/hooks/pre-commit

cat > "$HOOK" <<'HOOK_BODY'
#!/usr/bin/env bash
# pre-commit: entropy scan over staged content.
# Block on high-entropy strings that look like API keys / tokens.
# Override with `git commit --no-verify` (only when explicitly intended).

# R0.9: -e is safe here — the `grep '^+' | grep -v '^+++' | python3 -c ...`
# pipeline's exit status (with pipefail) is always the python3 script's own
# deliberate exit(0)/exit(1), even when an intermediate grep matches nothing
# (e.g. a pure-deletion diff), so a false abort on "no added lines" can't happen.
set -euo pipefail
ENTROPY_THRESHOLD=4.5  # bits per char (real API keys are 4.7+; long file paths hover 4.2-4.4)

# Get staged content (added or modified)
diff=$(git diff --cached --diff-filter=AM)
if [[ -z "$diff" ]]; then exit 0; fi

# Pull high-entropy candidates from added lines (+/-)
echo "$diff" | grep '^+' | grep -v '^+++' | python3 -c '
import sys, re, math
from collections import Counter

def entropy(s):
    if len(s) < 20: return 0.0
    p = Counter(s)
    return -sum((c/len(s)) * math.log2(c/len(s)) for c in p.values())

# Strings we explicitly allow (project conventions)
ALLOWED = re.compile(r"(sha256|pdf-1\.4|noqa|hash:|license|http[s]?://|/api/|paperless|/static|class=\"[A-Za-z0-9_-]+\"|/home_ai/|/home/joly|\.claude/|gpg --|0x[0-9a-fA-F]{6,}\$|jolyon|sandercock|sprints/)", re.I)

hits = 0
for line in sys.stdin:
    if ALLOWED.search(line): continue
    for m in re.findall(r"[A-Za-z0-9+/_=-]{32,}", line):
        e = entropy(m)
        if e > '"$ENTROPY_THRESHOLD"':
            # Skip if line is clearly a CSRF token, a UUID, or similar non-secret artifact
            if re.search(r"(CSRF|uuid|UUID)", line): continue
            print(f"[pre-commit] BLOCK: entropy={e:.2f} match={m[:40]}…")
            print(f"   line:  {line.strip()[:120]}")
            hits += 1
            if hits >= 5:
                break
    if hits >= 5:
        break

if hits > 0:
    print()
    print("[pre-commit] Refusing commit — high-entropy strings look like secrets.")
    print("[pre-commit] If these are not secrets, override with: git commit --no-verify")
    sys.exit(1)
sys.exit(0)
'
HOOK_BODY

chmod +x "$HOOK"
echo "✓ installed $HOOK"
