#!/bin/bash
# /home_ai/.claude/scripts/u26-setup-git-remote.sh
#
# Enable the git-push block at the bottom of /home_ai/scripts/backup-all.sh.
# This is currently commented out for safety — we need to be sure the remote
# is private + nothing sensitive will leak.
#
# What this script does:
#   1. Verifies /home_ai is a git repo (init if not, with a sensible .gitignore)
#   2. Prompts for the remote URL (typically: git@github.com:you/homeai.git)
#   3. Adds the remote AS "off-host-backup" (won't conflict with any existing)
#   4. Does a dry-run to verify access
#   5. Inspects what would be committed — explicit denylist of anything that
#      looks like a secret / credential / .env / vault data
#   6. If clean, uncomments the push block in backup-all.sh
#   7. Stages + commits an initial baseline
#   8. Pushes the baseline manually so you can verify on the remote
#
# Aborts safely if any check fails. Re-runnable.
#
# Run as your normal user. Needs network to reach the remote.

set -uo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

REPO=/home_ai
GITIGNORE=$REPO/.gitignore
BACKUP=$REPO/scripts/backup-all.sh

cd "$REPO" || { echo -e "${RED}✗${NC} can't cd to $REPO"; exit 1; }

echo -e "${CYAN}── U26: Backup git push setup ──${NC}"
echo

# ── 1. git init if needed ────────────────────────────────────────────────────
if [[ ! -d .git ]]; then
  echo -e "${YEL}→${NC} no .git directory — initialising"
  git init -q
  git checkout -q -b main 2>/dev/null || git checkout -q main
  git config user.email "homeai@${HOSTNAME:-local}"
  git config user.name  "Home AI"
  echo -e "${GREEN}✓${NC} repo initialised"
else
  echo -e "${GREEN}✓${NC} .git already present"
fi

# Normalise default branch to 'main' (push target). Handles repos that were
# init'd before init.defaultBranch=main was set.
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [[ "$current_branch" == "master" ]]; then
  if git show-ref --verify --quiet refs/heads/main; then
    echo -e "${RED}✗${NC} both 'master' and 'main' exist locally — resolve manually"
    exit 1
  fi
  echo -e "${YEL}→${NC} renaming local branch master → main"
  git branch -m master main
fi

# ── 2. Strong .gitignore — never ship secrets / data / volumes ──────────────
echo -e "${YEL}→${NC} ensuring .gitignore covers all known dangerous paths"
cat > "$GITIGNORE" <<'EOF'
# Volumes + binary data
/backups/
/storage/
/staging/
/n8n_data/
/vault_data/

# Secret patterns
*.env
*.env.*
.env*
*secret*
*credential*
*password*
*.pem
*.key
*_rsa
*_dsa
*_ed25519

# Vault encrypted bundles
*.gpg
/security/.vault-*

# Authelia secrets
/security/authelia/users_database.yml
/security/authelia-v2/users_database.yml

# Restic
.restic-pw
.restic-repo

# Local-only state
/tmp/
/var/
*.pyc
__pycache__/
.DS_Store
*.swp

# Build artefacts
node_modules/
EOF
git add .gitignore >/dev/null 2>&1
echo -e "${GREEN}✓${NC} .gitignore covers env / secret / volume / restic / authelia"

# ── 3. Prompt for remote ────────────────────────────────────────────────────
existing=$(git remote get-url off-host-backup 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  echo -e "${GREEN}✓${NC} remote 'off-host-backup' already set: $existing"
  read -rp "Keep this remote? [Y/n]: " keep
  if [[ "${keep:-Y}" =~ ^[Nn] ]]; then
    git remote remove off-host-backup
    existing=""
  fi
fi

if [[ -z "$existing" ]]; then
  echo
  echo "Provide a PRIVATE git remote (GitHub / Gitea / Forgejo / Codeberg)."
  echo "If it's GitHub: create a new EMPTY private repo first, paste the SSH URL."
  echo "  e.g. git@github.com:yourname/homeai-config.git"
  read -rp "Remote URL: " url
  if [[ -z "$url" ]]; then
    echo -e "${RED}✗${NC} no URL given — abort"
    exit 1
  fi
  git remote add off-host-backup "$url"
  echo -e "${GREEN}✓${NC} added remote 'off-host-backup' → $url"
fi

# ── 4. Dry-run access ───────────────────────────────────────────────────────
echo -e "${YEL}→${NC} testing remote access (ls-remote dry-run)"
if ! git ls-remote off-host-backup &>/dev/null; then
  echo -e "${RED}✗${NC} can't reach the remote — check SSH key / network / repo URL"
  echo "    tip: 'ssh -T git@github.com' should succeed"
  exit 1
fi
echo -e "${GREEN}✓${NC} remote reachable"

# ── 5. Forbidden-files check before staging ─────────────────────────────────
echo -e "${YEL}→${NC} scanning tree for secret-shaped files that .gitignore should be hiding"
suspicious=$(find . -type f \
  \( -name '*.env' -o -name '*secret*' -o -name '*credential*' \
     -o -name '*.pem' -o -name '*.key' -o -name '*_rsa' \
     -o -name '*_dsa' -o -name '*_ed25519' \
     -o -name '*.restic-pw' \) \
  ! -name '*.sh' ! -name '*.py' ! -name '*.md' \
  -not -path './backups/*' -not -path './.git/*' -not -path './n8n_data/*' \
  -not -path './vault_data/*' 2>/dev/null | head -10)
if [[ -n "$suspicious" ]]; then
  echo -e "${RED}✗${NC} found files matching secret patterns OUTSIDE the ignored dirs:"
  echo "$suspicious" | sed 's/^/    /'
  echo
  echo "Add explicit ignores or delete before continuing. Aborting for safety."
  exit 1
fi
echo -e "${GREEN}✓${NC} no secret-shaped files outside ignored paths"

# ── 6. What would actually be committed? ───────────────────────────────────
echo -e "${YEL}→${NC} files that would land in the first commit:"
git add -A --dry-run | head -30
total=$(git add -A --dry-run 2>/dev/null | wc -l)
echo "    ($total files total)"
echo
read -rp "Looks safe? Continue with initial commit + push? [y/N]: " ok
if [[ ! "${ok:-N}" =~ ^[Yy] ]]; then
  echo "aborted — nothing committed."
  exit 0
fi

# ── 7. Uncomment the push block in backup-all.sh ────────────────────────────
echo -e "${YEL}→${NC} uncommenting git-push block in backup-all.sh"
if grep -q '^# cd /home_ai && \\$' "$BACKUP"; then
  # Match the 4 commented lines (single trailing backslash for line continuation)
  # and uncomment them. Use python to avoid sed quoting gymnastics.
  python3 - "$BACKUP" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    src = f.read()
old = (
    "# cd /home_ai && \\\n"
    "#   git add -A && \\\n"
    "#   git commit -m \"backup: weekly snapshot $(date +%Y-%m-%d)\" --allow-empty && \\\n"
    "#   git push origin main\n"
)
new = (
    "cd /home_ai && \\\n"
    "  git add -A && \\\n"
    "  git commit -m \"backup: weekly snapshot $(date +%Y-%m-%d)\" --allow-empty && \\\n"
    "  git push off-host-backup main\n"
)
if old not in src:
    print("EXACT_BLOCK_NOT_FOUND")
    sys.exit(2)
open(path, "w").write(src.replace(old, new, 1))
PYEOF
  if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} push block uncommented + remote name swapped to 'off-host-backup'"
  else
    echo -e "${YEL}!${NC} comment block didn't match expected layout — leaving backup-all.sh untouched"
    echo "    you'll need to manually uncomment the git push block at the bottom of:"
    echo "    $BACKUP"
  fi
elif grep -q '^cd /home_ai && \\$' "$BACKUP"; then
  echo -e "${GREEN}✓${NC} push block already uncommented (idempotent re-run)"
else
  echo -e "${YEL}!${NC} couldn't find the comment pattern — leaving backup-all.sh untouched"
  echo "    you'll need to manually uncomment the git push block at the bottom of:"
  echo "    $BACKUP"
fi

# ── 8. Initial commit + push ────────────────────────────────────────────────
git add -A
git commit -m "homeai: initial off-host config snapshot $(date -u '+%Y-%m-%dT%H:%M:%SZ')" --allow-empty || true
echo -e "${YEL}→${NC} pushing to off-host-backup main…"
if git push -u off-host-backup main; then
  echo -e "${GREEN}✓${NC} initial baseline pushed"
else
  echo -e "${RED}✗${NC} push failed — manually inspect with 'git push -u off-host-backup main'"
  exit 1
fi

# ── 9. Update debt.yaml ─────────────────────────────────────────────────────
DEBT=/home_ai/services/build-dashboard/data/debt.yaml
if grep -q 'Backup-all.sh git push commented' "$DEBT"; then
  python3 -c "
import re
src = open('$DEBT').read()
src = re.sub(r'\n\s*- severity: low\n\s*title: Backup-all\.sh git push commented.*?(?=\n  - |\Z)', '', src, count=1, flags=re.DOTALL)
open('$DEBT', 'w').write(src)
"
  echo -e "${GREEN}✓${NC} removed git-push debt entry"
fi

echo
echo -e "${GREEN}── done ──${NC}"
echo "From the next weekly backup run (Sun 04:00 if you've installed that cron)"
echo "the config tree will push to off-host-backup. Verify on the remote next week."
