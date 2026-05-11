---
name: check-partitions
description: Verify events table partitions and overflow count
---
Run these queries:
1. SELECT tableoid::regclass, COUNT(*) FROM events GROUP BY 1 ORDER BY 1
2. SELECT COUNT(*) FROM events_overflow
3. SELECT tablename FROM pg_tables WHERE tablename LIKE 'events_%' ORDER BY tablename
Report: which monthly partitions exist, how many rows in each, overflow count (must be 0).
If overflow > 0, identify which months are missing and propose the CREATE TABLE fix.
