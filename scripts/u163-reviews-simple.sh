#!/bin/bash
# Simple TripAdvisor review extractor — regex-based, no API keys.
# Extracts review data from TripAdvisor notification emails.
# Idempotent: INSERT ... ON CONFLICT (source, review_id) DO NOTHING.

LOG=/home_ai/logs/u163-reviews-simple.log
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Run start" >> "$LOG"

# 2026-06-11 fix: `docker exec` WITHOUT -i discards the heredoc — psql received
# empty stdin, so this script had NEVER executed its SQL (exit 0, "Run complete",
# zero inserts, snags 57/59 falsely closed). The -i is load-bearing.
docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 << 'SQL'
DO $$
DECLARE
  r RECORD;
  v_rating INTEGER;
  v_body TEXT;
  v_date TEXT;
  v_review_id TEXT;
BEGIN
  FOR r IN (
    SELECT e.id, e.subject, e.body_text, e.received_at
    FROM emails e
    WHERE (e.from_address ILIKE '%tripadvisor%' OR e.subject ILIKE '%tripadvisor%')
      AND (e.subject ILIKE '%review%' OR e.subject ILIKE '%bubble%')
      AND e.received_at > now() - interval '90 days'
    ORDER BY e.received_at DESC
    LIMIT 10
  ) LOOP
    IF r.subject ~ '([0-9])-bubble' THEN
      v_rating := (regexp_match(r.subject, '([0-9])-bubble'))[1]::INTEGER;
    ELSE
      v_rating := 5;
    END IF;
    
    IF r.body_text ~ '\u201c[^\u201d]+\u201d' THEN
      v_body := (regexp_match(r.body_text, '\u201c([^\u201d]+)\u201d'))[1];
    ELSE
      v_body := 'Review text not available';
    END IF;
    
    IF r.body_text ~ '[0-9]{2}/[0-9]{2}/[0-9]{2}' THEN
      v_date := (regexp_match(r.body_text, '([0-9]{2}/[0-9]{2}/[0-9]{2})'))[1];
      v_date := '20' || split_part(v_date, '/', 3) || '-' || split_part(v_date, '/', 2) || '-' || split_part(v_date, '/', 1);
    ELSE
      v_date := r.received_at::date::text;
    END IF;
    
    v_review_id := 'ta-' || md5(r.subject || v_date);
    
    INSERT INTO guest_reviews (review_id, source, location, rating, posted_at, reviewer_name, body, status)
    VALUES (v_review_id, 'tripadvisor', 'malthouse', v_rating, (v_date || ' 12:00:00+00')::timestamptz, '', v_body, 'approved')
    ON CONFLICT (source, review_id) DO NOTHING;
    
  END LOOP;
END;
$$;
SQL

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Run complete" >> "$LOG"

# u278 (2026-06-11): Google Business Profile reviews — parsed from notification
# emails by a python companion (HTML-safe). Same 3-hourly cadence.
docker exec -i homeai-bot-responder python3 - < /home_ai/scripts/u278-google-reviews.py >> "$LOG" 2>&1

# u279 (2026-06-25): Expedia review notifications — placeholder per notification
# (Expedia email is notification-only; full review lives in Partner Central).
docker exec -i homeai-bot-responder python3 - < /home_ai/scripts/u279-expedia-reviews.py >> "$LOG" 2>&1
