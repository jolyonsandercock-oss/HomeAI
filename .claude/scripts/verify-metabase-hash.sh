#!/bin/bash
# Verifies that the password you typed matches the stored bcrypt hash.
# Helps tell whether (a) the hash function order is wrong (bug) vs
# (b) the password being entered into the UI differs from what was set
# (typo). Password never leaves this shell.
set -euo pipefail

read -rsp "Password to test: " PW
printf '\n'

# Test BOTH orderings: salt+password and password+salt
docker exec -i -e PW="$PW" homeai-postgres psql -U postgres -d metabase_app -tAc "
SELECT
  'stored password algo: ' || substring(password, 1, 7) AS algo,
  'salt prefix: ' || substring(password_salt, 1, 8) AS salt,
  'password matches (salt+pw, our scheme): ' ||
    (password = crypt(password_salt || '$PW', password))::text AS match_a,
  'password matches (pw+salt): ' ||
    (password = crypt('$PW' || password_salt, password))::text AS match_b,
  'password matches (no salt): ' ||
    (password = crypt('$PW', password))::text AS match_c
  FROM core_user WHERE email='jolyon.sandercock@gmail.com';
"
unset PW
