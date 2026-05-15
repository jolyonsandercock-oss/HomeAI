# Missing-data hunter summary

Generated 2026-05-15T20:29:45+01:00.

## Latest hunter run

```
all
work
ghost_shift_day=0
to_scrape_gap=0
dojo_settlement_gap=0
till_recon_missing=0
```

## Exception state per hunter kind

| kind | open | total seen | latest |
|---|---|---|---|
| ghost_shift_day | 9 | 9 | 2026-05-15 |
| till_recon_missing | 2 | 2 | 2026-05-15 |

## Cron

```
5 6 * * * /home_ai/scripts/u72-missing-data-hunters.sh >> /home_ai/storage/logs/u72-hunters.log 2>&1
30 6 * * * /home_ai/scripts/u75-pipeline-smoke.sh >> /home_ai/logs/u75-smoke.log 2>&1
```
