#!/usr/bin/env bash
# u63-authelia-users-prep.sh — prints a ready-to-apply patch for
# /home_ai/security/authelia-v2/users_database.yml. The file is root-
# owned by design, so Jo runs this once at the box:
#
#   bash /home_ai/scripts/u63-authelia-users-prep.sh > /tmp/u63-users.diff
#   sudo cp /home_ai/security/authelia-v2/users_database.yml \
#           /home_ai/security/authelia-v2/users_database.yml.bak-u63
#   # review /tmp/u63-users.diff, paste the new entries under `users:`
#   # (set real argon2id hashes via:
#   #   docker run --rm authelia/authelia:latest authelia hash-password 'p@ssw0rd!'
#   # )
#   sudo systemctl restart docker || docker restart homeai-authelia
#
# After Jo has set the hashes, /home_ai/security/authelia-v2/configuration.yml
# needs access_control rules added (see the bottom of this script).

set -euo pipefail

cat <<'YAML_USERS'
# --- additions to users_database.yml ---
#
# Drop these three blocks under the existing `users:` map. Replace each
# `<PASTE_ARGON2ID_HASH_HERE>` after running:
#   docker run --rm authelia/authelia:latest authelia hash-password 'YourPasswordHere'

users:
  accountant:
    displayname: "Accountant (read-only)"
    password: "<PASTE_ARGON2ID_HASH_HERE>"
    email: accountant@malthousetintagel.com
    groups:
      - finance
      - readonly

  pubstaff:
    displayname: "Pub Staff (Malthouse)"
    password: "<PASTE_ARGON2ID_HASH_HERE>"
    email: staff@malthousetintagel.com
    groups:
      - pub
      - readonly

  family:
    displayname: "Family Member"
    password: "<PASTE_ARGON2ID_HASH_HERE>"
    email: family@example.com
    groups:
      - home

YAML_USERS

cat <<'YAML_ACL'
# --- access_control additions to configuration.yml ---
# Add these rules to the existing access_control.rules: list (BEFORE any
# catch-all default_policy rule). The dashboard middleware (build-dashboard/
# main.py:_REALM_EXEMPT_PREFIXES + realm_middleware) already maps the
# Remote-Groups header → app.current_realm. Caddy already passes the
# Remote-Groups header through (see Caddyfile :94 forward_auth block).

access_control:
  default_policy: deny
  rules:
    # OWNER (jo) — full access
    - domain: jolybox.tailc27dff.ts.net
      subject: "group:admin"
      policy: one_factor

    # Pub staff: /pub, /touchoffice, /workforce, /api/pub/*, /api/touchoffice/*, /api/workforce/*
    - domain: jolybox.tailc27dff.ts.net
      subject: "group:pub"
      policy: one_factor
      resources:
        - "^/pub.*"
        - "^/touchoffice.*"
        - "^/workforce.*"
        - "^/api/(pub|touchoffice|workforce)/.*"
        - "^/m.*"
        - "^/api/m/.*"
        - "^/static/.*"

    # Accountant: read-only finance + invoices
    - domain: jolybox.tailc27dff.ts.net
      subject: "group:finance"
      policy: one_factor
      resources:
        - "^/finance.*"
        - "^/invoices.*"
        - "^/economics.*"
        - "^/api/(finance|invoices|economics|invoice)/.*"
        - "^/api/coverage/.*"
        - "^/static/.*"

    # Family: home view + tasks + calendar
    - domain: jolybox.tailc27dff.ts.net
      subject: "group:home"
      policy: one_factor
      resources:
        - "^/$"
        - "^/m.*"
        - "^/tasks.*"
        - "^/economics.*"
        - "^/documents.*"
        - "^/api/(tasks|calendar|documents|m|economics)/.*"
        - "^/static/.*"
YAML_ACL

cat <<'NEXT_STEPS'
# --- after applying ---
#
# 1. Hash the three placeholder passwords:
#      docker run --rm authelia/authelia:latest authelia hash-password 'YOUR_PW'
#    Paste into users_database.yml.
#
# 2. Restart Authelia:
#      docker compose restart authelia
#
# 3. Test login at https://jolybox.tailc27dff.ts.net/auth/ as each new user.
#
# 4. Confirm pubstaff lands on /pub with no access to /finance.
#
# 5. The /api/finance/ask Haiku route is realm-gated by the existing R2
#    middleware, so accountant users will only see work-realm finance data.
NEXT_STEPS
