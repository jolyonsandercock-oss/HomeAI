#!/usr/bin/env bash
# hermes-sentinel.sh — tamper-EVIDENT integrity monitor for the Hermes Agent.
#
# Threat model: a prompt injection (poisoned web page, email, document) tricks
# Hermes into planting persistence — a new cron job, kanban task, MCP server,
# hook, skill, webhook, quick-command, provider credential, message channel,
# or a loosened approval/allowlist. This script snapshots every such surface,
# canonicalises it, and diffs against an operator-approved baseline. Any drift
# is logged and pushed to Jo on Telegram.
#
# Honest limits: Hermes runs as the same Unix user, so a sufficiently clever
# compromise could edit this script or the baseline. This is tamper-EVIDENT
# (drift between approved state and reality), not tamper-PROOF. The baseline
# lives in /home_ai (outside ~/.hermes) and changes are also caught by the
# home_ai pre-push entropy scan + git.
#
# Usage:
#   hermes-sentinel.sh            # check (cron mode; silent when clean)
#   hermes-sentinel.sh --baseline # accept current state as the new baseline
#   hermes-sentinel.sh --show     # print the current snapshot
set -uo pipefail

H="$HOME/.hermes"
BASE="/home_ai/security/hermes-sentinel-baseline.json"
LOG="/home_ai/logs/hermes-sentinel.log"
SNAP="$(mktemp)"
trap 'rm -f "$SNAP"' EXIT

python3 - "$H" > "$SNAP" <<'EOF'
import hashlib, json, os, sqlite3, subprocess, sys
H = sys.argv[1]
snap = {}

# 1. Scheduled jobs (cron persistence)
try:
    jobs = json.load(open(f"{H}/cron/jobs.json"))["jobs"]
    snap["cron_jobs"] = sorted(
        [{"id": j["id"], "name": j.get("name"), "schedule": j.get("schedule_display"),
          "enabled": j.get("enabled"), "script": j.get("script"), "deliver": j.get("deliver"),
          "prompt_sha": hashlib.sha256((j.get("prompt") or "").encode()).hexdigest()[:16]}
         for j in jobs], key=lambda x: x["id"])
except Exception as e:
    snap["cron_jobs"] = f"ERROR {e}"

# 2. Kanban tasks (background work queue)
try:
    db = sqlite3.connect(f"file:{H}/kanban.db?mode=ro", uri=True)
    snap["kanban_open"] = sorted(
        f"{r[0]}|{r[1]}|{r[2]}" for r in db.execute(
            "SELECT id, status, title FROM tasks WHERE status NOT IN ('done','archived','cancelled')"))
except Exception as e:
    snap["kanban_open"] = f"ERROR {e}"

# 3. Security-relevant config
try:
    import yaml
    cfg = yaml.safe_load(open(f"{H}/config.yaml"))
    keys = ["mcp_servers", "command_allowlist", "hooks", "hooks_auto_accept",
            "quick_commands", "prefill_messages_file", "fallback_providers"]
    snap["config"] = {k: cfg.get(k) for k in keys}
    snap["config"]["security"] = cfg.get("security")
    snap["config"]["approvals"] = cfg.get("approvals")
    snap["config"]["model"] = {k: (cfg.get("model") or {}).get(k) for k in ("default", "provider", "base_url")}
    d = cfg.get("delegation") or {}
    snap["config"]["delegation"] = {k: d.get(k) for k in ("subagent_auto_approve", "model", "provider")}
    s = cfg.get("skills") or {}
    snap["config"]["skills"] = {k: s.get(k) for k in ("guard_agent_created", "inline_shell", "external_dirs")}
except Exception as e:
    snap["config"] = f"ERROR {e}"

# 4. Skills inventory (agent-created skills are a persistence vector)
sk = []
for root, _dirs, files in os.walk(f"{H}/skills"):
    for f in sorted(files):
        p = os.path.join(root, f)
        try:
            st = os.stat(p)
            sk.append(f"{os.path.relpath(p, H)}|{st.st_size}|{int(st.st_mtime)}")
        except OSError:
            pass
snap["skills_sha"] = hashlib.sha256("\n".join(sorted(sk)).encode()).hexdigest()
snap["skills_count"] = len(sk)

# 5. Hooks dir + SOUL.md + memory files (prompt-level persistence)
for name, path in [("hooks", "hooks"), ("soul", "SOUL.md"),
                   ("memory", "memories/MEMORY.md"), ("user_profile", "memories/USER.md")]:
    p = f"{H}/{path}"
    try:
        if os.path.isdir(p):
            items = []
            for root, _d, files in os.walk(p):
                for f in sorted(files):
                    fp = os.path.join(root, f)
                    items.append(f"{f}|{os.path.getsize(fp)}")
            snap[f"{name}_sha"] = hashlib.sha256("\n".join(sorted(items)).encode()).hexdigest()
        elif os.path.isfile(p):
            snap[f"{name}_sha"] = hashlib.sha256(open(p, "rb").read()).hexdigest()
        else:
            snap[f"{name}_sha"] = "absent"
    except Exception as e:
        snap[f"{name}_sha"] = f"ERROR {e}"

# 6. Messaging channels (a NEW chat/platform = talking to someone new)
try:
    ch = json.load(open(f"{H}/channel_directory.json"))["platforms"]
    snap["channels"] = sorted(
        f"{plat}:{c.get('id')}:{c.get('name')}" for plat, chats in ch.items() for c in chats)
except Exception as e:
    snap["channels"] = f"ERROR {e}"

# 7. Provider credentials present (new provider = new spend path)
try:
    a = json.load(open(f"{H}/auth.json"))
    snap["providers"] = {p: len(v) for p, v in (a.get("credential_pool") or {}).items()}
    snap["active_provider"] = a.get("active_provider")
except Exception as e:
    snap["providers"] = f"ERROR {e}"

# 8. Listening sockets owned by this user's python/node (new listener = drift)
try:
    out = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True, timeout=10).stdout
    socks = sorted({line.split()[3] for line in out.splitlines()
                    if "users:((" in line and ('"python' in line or '"node' in line)})
    snap["user_listeners"] = socks
except Exception as e:
    snap["user_listeners"] = f"ERROR {e}"

print(json.dumps(snap, indent=1, sort_keys=True, default=str))
EOF

mode="${1:-check}"
case "$mode" in
  --show) cat "$SNAP"; exit 0 ;;
  --baseline)
    mkdir -p "$(dirname "$BASE")"
    cp "$SNAP" "$BASE"
    echo "$(date -Is) BASELINE accepted ($(sha256sum "$BASE" | cut -c1-16))" | tee -a "$LOG"
    exit 0 ;;
esac

[ -f "$BASE" ] || { echo "$(date -Is) NO BASELINE — run with --baseline first" | tee -a "$LOG"; exit 2; }

if diff -u "$BASE" "$SNAP" > /tmp/hermes-sentinel.diff 2>&1; then
  echo "$(date -Is) OK" >> "$LOG"
  exit 0
fi

{
  echo "$(date -Is) DRIFT DETECTED"
  cat /tmp/hermes-sentinel.diff
  echo "---"
} >> "$LOG"

summary=$(grep -E '^[+-]' /tmp/hermes-sentinel.diff | grep -vE '^(\+\+\+|---)' | head -15)
PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH" hermes send -q -t telegram \
  "🛡️ HERMES SENTINEL: state drift detected. If you did not make this change, investigate before letting Hermes run further tasks.

${summary}

Full diff: /home_ai/logs/hermes-sentinel.log
Accept if legitimate: /home_ai/scripts/hermes-sentinel.sh --baseline" 2>>"$LOG" || \
  echo "$(date -Is) WARN: telegram alert failed" >> "$LOG"
exit 1
