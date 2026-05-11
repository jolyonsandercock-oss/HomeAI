# Skill: add-partition
Create a new monthly partition for the events table.

## When needed
- events_overflow count > 0
- Running the monthly partition creation pipeline manually
- Approaching end of month with no next partition

## SQL pattern
CREATE TABLE events_YYYY_MM PARTITION OF events
  FOR VALUES FROM ('YYYY-MM-01') TO ('YYYY-MM+1-01');

## Verify after creation
SELECT COUNT(*) FROM events_overflow;  -- must be 0
SELECT tablename FROM pg_tables WHERE tablename LIKE 'events_%' ORDER BY tablename;

## Gotchas
- Always check events_overflow AFTER creating — existing overflow rows don't auto-migrate
- Use DO $$ BEGIN IF NOT EXISTS ... END $$ for idempotent creation
