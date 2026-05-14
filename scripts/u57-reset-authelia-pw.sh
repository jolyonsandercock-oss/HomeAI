#!/usr/bin/env bash
# u57-reset-authelia-pw.sh — reset the Authelia password for user `jo`.
#
# Prompts silently for a new password (twice), generates an argon2id hash
# via Authelia's CLI inside the container, swaps it into users_database.yml
# (root-owned — sudo prompt), restarts Authelia.

set -euo pipefail

USER="jo"
USERS_DB="/home_ai/security/authelia-v2/users_database.yml"

echo "Reset password for Authelia user: ${USER}"
read -rsp "New password: " PW1 ; echo
read -rsp "Confirm:      " PW2 ; echo
[[ "${PW1}" == "${PW2}" ]] || { echo "ERROR: passwords don't match"; exit 1; }
[[ ${#PW1} -ge 12 ]]       || { echo "ERROR: password must be ≥12 chars"; exit 1; }

echo "Generating argon2id hash (~3s)..."
HASH=$(docker exec -i homeai-authelia \
    authelia crypto hash generate argon2 --password "${PW1}" 2>/dev/null \
    | awk -F': ' '/^Digest/ {print $2}')
unset PW1 PW2

[[ -n "${HASH}" ]] || { echo "ERROR: hash generation failed"; exit 1; }
echo "  hash starts: ${HASH:0:25}…"

echo "Writing new hash to users_database.yml (sudo prompt)..."
TMP=$(mktemp)
sudo cat "${USERS_DB}" > "${TMP}"
# Replace the password line for our user — single quotes around the hash.
python3 - "${TMP}" "${USER}" "${HASH}" <<'PYEOF'
import sys, re, pathlib
path, user, new_hash = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
pattern = re.compile(rf"(^  {re.escape(user)}:[\s\S]*?^    password:) '[^']*'", re.MULTILINE)
new_text, n = pattern.subn(rf"\1 '{new_hash}'", text)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 password line for user '{user}', found {n}")
pathlib.Path(path).write_text(new_text)
print(f"  patched {n} line")
PYEOF
sudo cp "${TMP}" "${USERS_DB}"
sudo chmod 600 "${USERS_DB}"
sudo chown root:root "${USERS_DB}"
rm -f "${TMP}"

echo "Restarting Authelia..."
cd /home_ai
docker compose restart authelia 2>&1 | tail -2

echo
echo "✓ Password reset. Try logging in at:"
echo "  https://jolybox.tailc27dff.ts.net/auth/"
