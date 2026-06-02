# TouchOffice 5-Year Backfill

Run the existing backfill script to populate epos_daily_reports with 5 years of historical data (2021-06-01 to 2026-05-30).

## Current State
- epos_daily_reports has data from 2025-05-13 to 2026-05-31 (349 malthouse days, 258 sandwich days)
- The backfill script exists: /home_ai/scripts/u27-touchoffice-backfill.sh
- It calls /ingest/touchoffice?site=malthouse|sandwich&date=YYYY-MM-DD
- Each (date, site) call takes ~75s, so each day is ~150s for both sites
- 5 years = ~1825 days = ~76 hours of running time

## Script Usage
```
./scripts/u27-touchoffice-backfill.sh 2021-06-01 2026-05-30 2
```
The "2" means 2-second delay between calls.

## Strategy
This will take ~3 days to run:
1. Start it as a background process with nohup
2. Log to /home_ai/logs/u63-touchoffice-backfill-5y.log
3. Monitor with `tail -f` occasionally
4. The script is idempotent - already-loaded rows are skipped

## Command to Run
```bash
cd /home_ai && nohup bash scripts/u27-touchoffice-backfill.sh 2021-06-01 2026-05-30 2 >> logs/u63-touchoffice-backfill-5y.log 2>&1 &
echo $! > /tmp/touchoffice-backfill.pid
```

## Verification
After starting:
- Check it is running: `ps aux | grep u27-touchoffice-backfill`
- Check progress: `tail -f logs/u63-touchoffice-backfill-5y.log`
- Check rows: `docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT count(*), min(report_date), max(report_date) FROM epos_daily_reports;"`
