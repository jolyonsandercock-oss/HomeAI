# U229 + U230 — On-site pairing steps (Jo, at the local machine)

The scaffolding is in place: stub scrapers + FastAPI endpoints. Two manual
steps remain that I can't do autonomously (auth ceremonies).

## 1. Vault: store credentials

```
# Set a VAULT_TOKEN env (from bot-responder's env, like the U70 pattern):
VT=$(docker inspect homeai-bot-responder \
     --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -e VAULT_TOKEN="$VT" homeai-vault \
  vault kv put secret/dojo username=… password=…

docker exec -e VAULT_TOKEN="$VT" homeai-vault \
  vault kv put secret/trail username=… password=…
```

## 2. Rebuild + recreate the playwright container

The `homeai-playwright` Docker image is baked, not volume-mounted (per
`feedback-dashboard-image-rebuild` pattern — applies here too).

```
cd /home_ai
docker compose build playwright-service
docker compose up -d --force-recreate playwright-service
docker logs -f homeai-playwright | grep -i 'startup\|ready\|error' | head
```

## 3. Pairing runs (Dojo first)

The pairing run opens a HEADED browser so you can:
- enter SMS/TOTP if Dojo prompts for 2FA
- see exactly which DOM selectors the login form uses
- confirm the storage_state.json is saved correctly

Dojo:
```
docker exec -it homeai-playwright bash -c '
  python3 -m scrapers.dojo --pair \
    --username "$(curl -s http://vault:8200/v1/secret/data/dojo -H "X-Vault-Token: $VAULT_TOKEN" | jq -r .data.data.username)" \
    --password "$(curl -s http://vault:8200/v1/secret/data/dojo -H "X-Vault-Token: $VAULT_TOKEN" | jq -r .data.data.password)"
'
```

During the headed pairing:
1. Update `scrapers/dojo.py` line `# TODO(Jo)` selectors to match what
   you see in the actual Dojo dashboard.
2. After successful auth, navigate to the transactions report.
3. Replace the `rows: list[dict[str, Any]] = []` stub with the actual
   table-scrape logic (use `page.locator("…").all_text_contents()` or
   similar — patterns from `scrapers/touchoffice.py`).
4. Save + exit; the storage_state file will persist for non-headed runs.

## 4. Same for Trail

Trail's OIDC flow lives at `identity.accessacloud.com`. The login form
selectors in `scrapers/trail.py` are best-guesses (`input[name="username"]`
etc.) — they may need adjusting once you see the real form.

```
docker exec -it homeai-playwright python3 -m scrapers.trail --pair \
  --username … --password …
```

## 5. Cron + verify

Once the scrapers return real rows, add the daily crons:

```
crontab -e   # as root
# Dojo: 05:30 (replaces u135-dojo-inbox-sweep.sh)
30 5 * * * curl -sS -X POST http://homeai-playwright:8001/ingest/dojo >> /home_ai/logs/u229-dojo.log 2>&1

# Trail: 06:00 (replaces u134-trail-poll.py)
0 6 * * * curl -sS -X POST http://homeai-playwright:8001/ingest/trail >> /home_ai/logs/u230-trail.log 2>&1
```

Then verify staleness drops:
- `v_dojo_freshness.hours_stale < 30` (was 8d+ before)
- `trail_reports.MAX(report_date)` advances daily

## Rollback

If anything goes wrong, the old crons still exist (commented or with
`#u135` / `#u134` tags). Restoring them is one crontab edit. The
playwright container can be reverted by checking out the previous
docker-compose tag.
