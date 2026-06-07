#!/usr/bin/env bash
# ask.sh — ask a data question from the terminal, via the controlled bot.
#
# Replaces the removed dashboard "Research" widget, which made a direct,
# unredacted, un-budgeted Claude call straight from a web surface (Codex F5).
# This instead enqueues the question for bot-responder — read-only slug tools,
# realm-scoped, usage-logged, behind the sender whitelist. bot-responder polls
# every minute and replies BY EMAIL to the owner address (its reply channel).
#
# For an in-terminal (stdout) answer instead of email, the bot needs a small
# tweak to write the answer into bot_instructions.resolution for source=
# 'terminal'; ask and it'll be added.
set -euo pipefail

Q="$*"
[ -z "$Q" ] && { echo "usage: $(basename "$0") <your question>"; exit 1; }

docker exec -i homeai-postgres psql -U postgres -d homeai \
  -v q="$Q" -v email='jolyon.sandercock@gmail.com' <<'SQL'
INSERT INTO bot_instructions
  (source, from_user, sender_email, raw_subject, raw_text,
   status, realm, received_at, ingested_at)
VALUES ('terminal', 'terminal', :'email', 'Terminal question', :'q',
        'pending', 'owner', now(), now())
RETURNING id AS queued_bi_id;
SQL

echo "Queued — bot-responder will answer by email to jolyon.sandercock@gmail.com within ~1 min."
