# security/cred-archive/

Archive for credential-shaped backup files that were previously sitting
loose in `/home_ai/backups/` (a general-purpose, gitignored dump
directory with mixed access — logs, SQL dumps, restic state, etc.).
This directory is 0700 joly-owned and is itself gitignored
(`/security/cred-archive/` in `.gitignore`), so nothing here is ever at
risk of being committed even though the underlying files are already
encrypted.

## Move log

- **2026-07-02 (R5 hygiene sweep):** moved
  `cred-0wPA4DCDuehPC9Mf-20260605T170419Z.bak` here from
  `/home_ai/backups/`. This is an n8n credential export/backup
  (openssl `enc`, salted, base64-encoded — verified encrypted via
  `file`, not plaintext JSON). Original mtime 2026-06-05 18:04.
  No other `cred-*` files were found elsewhere under `/home_ai/backups/`
  at the time of this sweep.

No secret contents, keys, or decrypted material are recorded in this
README — only file identity and provenance.
