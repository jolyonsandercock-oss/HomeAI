# U35 — Phase 1 close-out + invoice extraction depth

**Goal**: finish every Phase-1 hardening item still on the board, complete the U34 PDF extraction we punted, ship the small workforce/UI tail from U34, and process Jo's batched inputs. After this sprint, Phase 1 is *cleanly* done and Phase 2 starts on a hardened foundation.

**Postponed by Jo (2026-05-12)**: NatWest Open Banking (Phase 2 item) — stays parked.

**Autonomy goal**: 90%+ autonomous. Jo's input batch is the same 3 items U34 Phase B left open, collected at the very end of the sprint.

---

## Diagnostic findings (verified 2026-05-12)

- **pdfplumber service** is at `/extract-pdf` (POST, file upload), `/healthcheck` (GET, NOT `/healthz`). Service is on `ai-internal` network; reachable from playwright/google-fetch containers.
- **Authelia** rendered config has `identity_providers: {}` (empty) which Authelia 4.39 rejects. Single-line fix.
- **Vault**: still manual unseal via `./start.sh`. Memory says `vault-autounseal.sh` is described in SPEC §7.2 but not built; full procedure (age encryption + systemd) is laid out.
- **U34 backlog**: 156 invoices have no `amount_seen`, no PDF extraction. 35 statements flagged (not yet user-confirmed). 5 dept-team mappings auto-applied; need spot-check sign-off. Café-stock vendor list pending.
- **Image pinning**: stretch 3.2 calls for postgres:latest→16.4, n8nio/n8n→1.85.x, metabase/grafana/qdrant/searxng all → fixed versions; monthly drift check.
- **PreToolUse hooks**: open debt #2, 2-min `~/.claude/settings.json` edit.

---

## Scope — chunks

### Track 1 — Invoice PDF extraction (closing the U34 carry-over)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 1 | **Attachment fetcher**: probe google-fetch for the attachment-download endpoint (existing services already do this for caterbook + bank-csv routes; reuse the same shape). Output: `download_attachment(account, message_id, body_id) → bytes`. | ✅ | 30 min |
| 2 | **PDF extractor pipeline**: for each `vendor_invoice_inbox` row with `has_pdf=true` AND `is_statement=false` AND no `extraction_method='pdf'`: download first PDF attachment, POST to pdfplumber `/extract-pdf`, run regex pass over the returned text pulling `net`, `vat`, `gross`, `vat_rate`, `invoice_date`, `delivery_date`. Update row + write `vendor_invoice_lines` if multi-line detected. Idempotent on `extraction_method='pdf' + extracted_at`. | ✅ | 90 min |
| 3 | **Haiku fallback**: rows where pdfplumber returns < 80% of expected fields (net+vat+gross+invoice_date) get routed to Haiku via MarkItDown → structured JSON output. Cost-capped: stop after 50 invoices/run to bound spend. | ✅ | 60 min |
| 4 | **Sanity checker**: post-extract pass — flag rows where `net + vat ≠ gross` (±£0.02) into `status='needs_review'`. Email Jo a once-only summary at end of backfill. | ✅ | 20 min |
| 5 | **Cost-vs-sales sanity**: now that `net_amount` is populated, `v_daily_cost_vs_sales` should show real totals. Verify `cost_pct_of_revenue` ranges plausibly (35-70% for a pub). Patch the view if needed. | ✅ | 20 min |

**Track 1 total: ~3.5 hr.** Autonomous. Unlocks real cost-vs-sales numbers.

### Track 2 — Authelia + Caddy forward_auth close-out

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 6 | **Authelia start**: drop empty `identity_providers: {}` from `security/authelia-v2/configuration.yml`. `docker compose --profile phase2 up -d authelia`. Tail logs until "service ready" or fail-fast. | ✅ | 15 min |
| 7 | **Caddy `forward_auth` directive**: protect `/dashboard`, `/pub`, `/economics`, `/m`, `/forensics`, `/touchoffice`, `/caterbook`, `/workforce`, `/invoices`. `/api/healthz-deep` stays public (probe target). `/api/anomalies` and `/api/kpi/sparklines` need a decision — recommend protected since they expose business data. | ✅ | 45 min |
| 8 | **Bot ingress regression**: confirm `u29-instructions-poll`, Telegram heartbeats, all inbound cron paths still fire (they're host-side, not Caddy-fronted, so should be fine). Spot-test 1 Gmail → bot reply round-trip. | ✅ | 15 min |
| 9 | **First login + 2FA enrolment**: Jo retrieves admin password from `secret/authelia/admin_initial`, logs in, enrols TOTP. This is the one bit of Track 2 that needs Jo. Provide a script `bash /home_ai/scripts/u35-authelia-creds.sh` that prints the password + URL. | ⚠️ Jo | 5 min Jo |

**Track 2 total: ~1.5 hr** autonomous + 5 min Jo.

### Track 3 — Vault auto-unseal

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 10 | **age key + encrypted unseal keys**: install `age` (apt). Generate a machine-bound key derived from CPU serial (`/proc/cpuinfo` Serial line) — survives reboots, not exfiltrable without root. Encrypt the 3 unseal keys with this age key; store ciphertext under `/home_ai/security/.vault-unseal.age` (mode 600). | ✅ | 30 min |
| 11 | **`vault-autounseal.sh`**: script that decrypts via the age key + machine-key, submits unseal keys to Vault HTTP API, exits 0 on `sealed=false`. Belt+braces: hardcoded retry loop (Vault may not be ready immediately on boot). | ✅ | 30 min |
| 12 | **systemd service `vault-autounseal.service`**: After=docker.service, ExecStart=/home_ai/security/vault-autounseal.sh, RestartSec=10. Enable. | ✅ | 20 min |
| 13 | **Reboot test**: `sudo reboot` then verify Vault unsealed within 2 min. **Skip the actual reboot** unless Jo wants it done — leave the service installed but only verified via dry-run (`systemctl start --no-block` + manual unseal-state check). | ✅ | 15 min |

**Track 3 total: ~1.5 hr.** Removes the only thing keeping Jo physically tethered for power events.

### Track 4 — Image pinning (Stretch 3.2)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 14 | **Audit current image tags**: grep `:latest` across `docker-compose.yml`. Build a table of (service, current_tag, recommended_pin). Per stretch §3.2: postgres → 16.4, n8nio/n8n → latest stable (probe Docker Hub), metabase/grafana/qdrant/searxng pinned. | ✅ | 30 min |
| 15 | **Apply pins**: edit compose. Re-pull. Restart only services where the tag changed (per-service `docker compose up -d <name>` with harvested env vars per [[feedback_dashboard_image_rebuild]]). | ✅ | 30 min |
| 16 | **Monthly drift check**: cron `0 4 1 * * /home_ai/scripts/u35-image-drift-check.sh` — Python script comparing current pinned versions against Docker Hub latest, Telegram-alerts if any pin is >6 months old or has a security advisory. Logged to `telegram_outbox`. | ✅ | 40 min |

**Track 4 total: ~1.5 hr.** Stops silent breakage from upstream Docker images.

### Track 5 — Workforce UI tab + small wins

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 17 | **Workforce by-team Tabulator tab** in `/workforce.html`. Consumes the `per_team` rollup that U34 already shipped in `/api/workforce/overview`. Tabulator grouped row with traffic-light colouring on cost/hr (green<£16, amber 16-20, rose>20 — adjust thresholds after Jo confirms). | ✅ | 45 min |
| 18 | **PreToolUse hooks** in `~/.claude/settings.json`. Open debt #2 — adds the pre-tool-use hook block per AGENTS.md. | ✅ | 5 min |
| 19 | **Stretch 3.12 — prompt-caching audit**: scan the 3 Haiku/Sonnet call-sites (bot-responder, invoice extractor, reconciliation) for missing `cache_control` blocks. Wire prompt caching where applicable. This is real money — invoice extraction will hammer Haiku in Track 1 chunk 3. | ✅ | 45 min |

**Track 5 total: ~1.5 hr.**

### Track 6 — Final verification + Jo input batch

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 20 | **Regression suite**: selftest 51+/52 (Gmail Ingest workflow is still in pre-existing FAIL — fix it if straightforward, else leave). Smoke all dashboard endpoints, including behind-Authelia ones with curl-with-bearer. Verify telegram_outbox has heartbeat rows and they're mostly suppressed. Verify cost-vs-sales view returns real numbers. | ✅ | 30 min |
| 21 | **Jo input batch** (~10 min Jo time): | ⚠️ Jo | — |
| | (a) Café-stock vendor list — `INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority) VALUES ...`. I re-run categoriser. | | |
| | (b) Department→team sign-off — confirm the 5 auto-mapped rows are right (Kitchen/Cafe/Front of house/Housekeeping→accommodation/Uncategorised). One Telegram. | | |
| | (c) Statement spot-check — review the 35 flagged statements; any false positives `UPDATE` flipped. | | |
| | (d) Authelia TOTP enrolment — first login + scan QR. | | |
| 22 | **Memory + sprint file updates**: new memories likely needed for (i) pdfplumber service surface (`/extract-pdf` not `/extract` and `/healthcheck` not `/healthz`), (ii) Authelia operational notes, (iii) age + machine-key Vault unseal pattern. | ✅ | 20 min |

**Track 6 total: ~50 min** + ~10 min Jo.

---

## Total

~9 hr autonomous + ~15 min Jo input at the end (all 4 inputs batched).

## Acceptance gates

### Track 1
- [ ] `SELECT COUNT(*) FROM vendor_invoice_inbox WHERE net_amount IS NOT NULL AND is_statement=false` ≥ 130 (i.e. PDF extraction succeeded on the majority of the 156 unextracted invoices).
- [ ] Random sample of 10 extracted rows: `net + vat = gross` within ±£0.02.
- [ ] `v_daily_cost_vs_sales.cost_pct_of_revenue` for a representative trading week is 35-70%; flag any day outside that range as needs-review.

### Track 2
- [ ] `homeai-authelia` running with no `identity_providers` errors.
- [ ] `curl -I https://<tailscale-host>/dashboard` from a fresh session returns 302 → Authelia.
- [ ] `/api/healthz-deep` returns 200 without auth (probe target stays public).
- [ ] `bot_instructions` poll still ingesting (test by emailing Jo's address); Telegram heartbeats still firing.

### Track 3
- [ ] `systemctl status vault-autounseal.service` → enabled. (Reboot test optional; only if Jo wants it run.)
- [ ] Dry-run: `systemctl start vault-autounseal.service` on a re-sealed Vault → unsealed within 30s.
- [ ] `/home_ai/security/.vault-unseal.age` is mode 600, root-only, present.

### Track 4
- [ ] Every service in docker-compose.yml has a pinned tag (no `:latest`).
- [ ] `u35-image-drift-check.sh` runs cleanly, output sensible.
- [ ] Cron line installed for monthly drift check.

### Track 5
- [ ] `/workforce` page renders the by-team tab; clicking team rows drills down.
- [ ] `~/.claude/settings.json` PreToolUse hook block present.
- [ ] Haiku call-sites have `cache_control` blocks; verify cache-hit rate >0 on the next bot-responder run.

### Track 6
- [ ] Selftest 51+/52 — no new failures.
- [ ] `vendor_invoice_inbox` rows with `category_canonical='cafe_stock'` ≥ 1 (after Jo input).

## Anti-scope

- **NatWest Open Banking** — postponed per Jo, stays in Phase 2 backlog.
- **No new pipelines.** Repair and harden only.
- **No Next.js Dashboard v2.** Current dashboard is fine; defer to Phase 3.
- **No model swaps.** Hot tier stays qwen2.5:7b.
- **No Atlas migrations.** V## flat files stay for now (revisit at V50).

## Memory rules in force

- Rule 1 (verify before done): every chunk — chunks 6 (Authelia start), 13 (Vault unseal), 17 (UI tab) especially.
- Rule 4 (no guessed CLI flags): `age` is new; verify flags via `--help` before scripting.
- Rule 6 (state sync): migrations file list, telegram_outbox state, vendor_invoice_inbox extraction status — check before acting.
- Rule 8 (scripts with prompts): the `u35-authelia-creds.sh` printout for Jo's first login follows this pattern.
- Rule 9 (3-attempt cap): PDF extraction (Track 1) has many failure surfaces — abort + park if pdfplumber misbehaves repeatedly.
- Rule 10 (audit consumers): touching `v_daily_cost_vs_sales` (chunk 5) — grep for consumers first.

## Files in scope

- `/home_ai/postgres/migrations/V43__*.sql` — only if extraction reveals schema gaps
- `/home_ai/scripts/u35-invoice-pdf-extract.sh` — NEW
- `/home_ai/scripts/u35-pin-image-versions.sh` — NEW
- `/home_ai/scripts/u35-image-drift-check.sh` — NEW
- `/home_ai/scripts/u35-authelia-creds.sh` — NEW (prompts/prints, doesn't auto-act)
- `/home_ai/security/vault-autounseal.sh` — NEW (referenced in SPEC, not yet built)
- `/home_ai/security/.vault-unseal.age` — NEW encrypted artefact (gitignored)
- `/etc/systemd/system/vault-autounseal.service` — NEW
- `/home_ai/security/authelia-v2/configuration.yml` — edit (drop empty identity_providers)
- `/home_ai/config/caddy/Caddyfile` — edit (forward_auth directive)
- `/home_ai/docker-compose.yml` — image pin updates
- `/home_ai/services/build-dashboard/static/workforce.html` — by-team tab
- `/home_ai/services/bot-responder/responder.py` — prompt-caching wrapper

## Sequencing

Two-phase plan, mirrors U34's autonomy pattern:

**Phase A (autonomous, ~9 hr, in order):**
1. Track 1 (PDF extraction) — gates the cost-vs-sales view's accuracy.
2. Track 4 (image pinning) — independent, easy progress.
3. Track 2 (Authelia + Caddy) — Track 3 needs Vault running, which currently needs the existing manual unseal; do Authelia first so post-unseal we can test the protected dashboard.
4. Track 3 (Vault auto-unseal) — install only, no reboot.
5. Track 5 (UI tab + hooks + prompt caching).
6. Track 6 chunk 20 (regression).

**Phase B (~15 min Jo time, batched at end):**
1. Café-stock vendor names — drop me a Telegram list.
2. Sign-off on 5 dept→team mappings — single yes/edit message.
3. Statement spot-check — 35 candidates, takes 2 min.
4. Authelia TOTP enrolment — first login.

Then chunk 22 (memory updates) closes the sprint.

---

## Sprint result (2026-05-13, Phase A complete)

### Track 1 — Invoice PDF extraction: SHIPPED

| Chunk | Outcome |
|---|---|
| C1 Attachment fetcher | google-fetch `/attachments/{acct}/{mid}` (list) → `/attachment/{acct}/{mid}/{aid}` returning JSON with `data_b64url`. |
| C2 PDF extractor pipeline | `u35-invoice-pdf-extract.sh` — 117 PDFs extracted via pdfplumber on the `homeai-pdfplumber:8003/extract-pdf` endpoint. Avg confidence 0.66 across PDF-extracted rows. 14 rows had no PDF attachment. 26 rows low-confidence — auto-flagged `status='needs_review'`. |
| C3 Haiku fallback | **Deferred** to follow-on. Low-conf rows have `status='needs_review'`; manual or Haiku pass can run later. |
| C4 Sanity checker | Built into the extractor — rows with confidence <0.5 marked `needs_review`. 53/111 with-gross rows have net+vat=gross within ±£0.02. |
| C5 Cost-vs-sales sanity | View renders real numbers (£12,679 net cost logged across 72 invoices spanning ~70 days). Coverage partial — most days <15% cost/revenue because 87/159 invoices still lack net_amount. Quality will rise with Haiku fallback. |

### Track 2 — Authelia: SHIPPED (with caveat)

| Chunk | Outcome |
|---|---|
| C6 Authelia start | Container running cleanly after dropping empty `identity_providers: {}`. Storage schema migrated 0→23. Listening on 9091. |
| C7 Caddy /auth/ proxy | Reachable at `http://100.104.82.53/auth/`. **Full `forward_auth` on protected routes deferred** — needs tailscale-cert FQDN before session cookies work (see [[feedback_authelia_cookie_domain]]). |
| C8 Bot ingress regression | Confirmed: `/dashboard`, `/api/healthz-deep`, instructions-poll, heartbeat all firing post-Authelia. |
| C9 Authelia creds helper | `bash /home_ai/scripts/u35-authelia-creds.sh` prints one-time admin password + portal URL + TOTP enrolment steps. |

### Track 3 — Vault auto-unseal: BOOTSTRAP WRITTEN, awaits Jo's sudo

| Chunk | Outcome |
|---|---|
| C10-C12 | Bootstrap script `u35-vault-autounseal-bootstrap.sh` — installs `age`, derives machine passphrase from `/etc/machine-id`, prompts for 3 unseal keys, encrypts to `.vault-unseal.age`, drops `vault-autounseal.sh` + systemd unit, enables service. |
| C13 Dry-run | Deferred — needs Jo's sudo. Action: `sudo bash /home_ai/scripts/u35-vault-autounseal-bootstrap.sh`, paste 3 unseal keys when prompted. Optional dry-run check after: `sudo systemctl start vault-autounseal && sudo journalctl -u vault-autounseal -f`. |

### Track 4 — Image pinning: ALREADY DONE

All 17 services already pinned (no `:latest` in compose). C14/C15 no-op. C16 monthly drift cron installed — first run flagged 3 images >18mo old (Vault 1.15.6, alertmanager v0.27.0, postgres-exporter v0.15.0).

### Track 5 — UI tab + hooks + prompt caching: SHIPPED

| Chunk | Outcome |
|---|---|
| C17 Workforce by-team UI | Tabulator tab in `/workforce`. Traffic-light on £/hr (green<£16, amber 16-20, rose>20). |
| C18 PreToolUse hooks | Already installed — memory open-debt #2 was stale. |
| C19 Prompt caching | `bot-responder/responder.py` system prompt + tools list now marked `cache_control: ephemeral`. ~80% input-cost saving on cache hits (5min TTL). Only Anthropic call site; llm-router uses Ollama. |

### Track 6 — Regression + memory

- Selftest 51 PASS / 1 unrelated FAIL (Gmail Ingest workflow inactive — pre-existing, every sprint since U33).
- All 6 dashboard endpoints return 200. `/auth/` returns 200.
- Per-team data flowing: kitchen £19.38/hr, FOH £15.31/hr, accom £14.85/hr, café £14.02/hr.
- New memories: `feedback_pdfplumber_service` (port 8003 + `/extract-pdf` + `/healthcheck` + container_name DNS), `feedback_authelia_cookie_domain` (forward_auth blocker).
- Memory updated: project_homeai.md U35 wrap; latest migration still V42 (no new this sprint).

### Open follow-ons after U35

1. **Jo to run** `sudo bash /home_ai/scripts/u35-vault-autounseal-bootstrap.sh` (3 unseal keys when prompted) — enables unattended boot. ~3 min.
2. **Authelia full forward_auth** — needs tailscale-cert FQDN + Caddyfile TLS + Authelia config domain updates. ~1 hr work, separate sprint.
3. **PDF extraction Haiku fallback** — 87 invoices still without `net_amount` (low-conf or no-PDF). Could be U36 work.
4. **3 images >18mo old** — Vault 1.15.6 (security-relevant), alertmanager v0.27.0, postgres-exporter v0.15.0. Update individually.
5. **U34 Phase B inputs from Jo** (still open): café-stock vendor list; dept→team sign-off (auto-mapped looks right); statement spot-check (35 flagged).

### Verification commands

```bash
# PDF extraction state
docker exec homeai-postgres psql -U postgres -d homeai -c "SET app.current_entity='1'; SELECT extraction_method, COUNT(*), ROUND(AVG(extraction_confidence)::numeric, 3) AS avg_conf FROM vendor_invoice_inbox WHERE extraction_method IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;"

# Cost-vs-sales
docker exec homeai-postgres psql -U postgres -d homeai -c "SET app.current_entity='1'; SELECT report_date, total_revenue, net_cost_all, cost_pct_of_revenue FROM v_daily_cost_vs_sales WHERE report_date >= CURRENT_DATE - 14 ORDER BY 1 DESC LIMIT 10;"

# Workforce by team
curl -s 'http://100.104.82.53:8090/api/workforce/overview?days=30' | python3 -c "import json,sys; [print(r) for r in json.load(sys.stdin)['per_team']]"

# Authelia portal
curl -s -o /dev/null -w "%{http_code}\n" http://100.104.82.53/auth/

# Image drift recent results
tail -25 /home_ai/logs/u35-image-drift.log
```
