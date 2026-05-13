#!/bin/bash
# /home_ai/scripts/u39-insert-review.sh
#
# Interactive review insert — until the auto-scraper exists, Jo (or anyone
# whitelisted) can paste a Google/TripAdvisor review and queue it for
# Sonnet drafting + Action Queue review.

set -uo pipefail

PSQL() { docker exec -i homeai-postgres psql -U postgres -d homeai "$@"; }

echo
echo "╭─ Insert guest review ──────────────────────────────────────╮"
echo

read -rp "  source (google / tripadvisor): " SOURCE
[[ "$SOURCE" == "google" || "$SOURCE" == "tripadvisor" ]] || { echo "✗ source must be google or tripadvisor"; exit 1; }

read -rp "  location (malthouse / sandwich): " LOCATION
[[ "$LOCATION" == "malthouse" || "$LOCATION" == "sandwich" ]] || { echo "✗ location must be malthouse or sandwich"; exit 1; }

read -rp "  rating (1-5): " RATING
[[ "$RATING" =~ ^[1-5]$ ]] || { echo "✗ rating must be 1-5"; exit 1; }

read -rp "  reviewer name (Enter for anonymous): " REVIEWER
read -rp "  review_id (unique, e.g. paste the URL hash, or 'manual-$(date +%s)'): " RID
[[ -z "$RID" ]] && RID="manual-$(date +%s)"

echo "  review body (multi-line OK, end with Ctrl-D):"
BODY=$(cat)
[[ -z "$BODY" ]] && { echo "✗ body required"; exit 1; }

read -rp "  posted_at ('now' or YYYY-MM-DD): " POSTED
[[ -z "$POSTED" || "$POSTED" == "now" ]] && POSTED_SQL="now()" || POSTED_SQL="'$POSTED'::timestamptz"

ESCAPED_REVIEWER=$(printf "%s" "$REVIEWER" | sed "s/'/''/g")
ESCAPED_BODY=$(printf "%s" "$BODY" | sed "s/'/''/g")
ESCAPED_RID=$(printf "%s" "$RID" | sed "s/'/''/g")

PSQL -v ON_ERROR_STOP=1 <<SQL
SET app.current_entity='1';
INSERT INTO guest_reviews (review_id, source, location, rating, reviewer_name, body, posted_at)
VALUES ('$ESCAPED_RID', '$SOURCE', '$LOCATION', $RATING,
        NULLIF('$ESCAPED_REVIEWER', ''),
        '$ESCAPED_BODY', $POSTED_SQL)
ON CONFLICT (source, review_id) DO UPDATE SET
  rating = EXCLUDED.rating, body = EXCLUDED.body, reviewer_name = EXCLUDED.reviewer_name,
  posted_at = EXCLUDED.posted_at, scraped_at = now(), status = 'new';
SELECT review_id, source, rating, status FROM guest_reviews WHERE review_id = '$ESCAPED_RID';
SQL

echo
echo "✓ review queued. Drafter runs every 10 minutes — or run it now:"
echo "  bash /home_ai/scripts/u39-review-drafter.sh"
