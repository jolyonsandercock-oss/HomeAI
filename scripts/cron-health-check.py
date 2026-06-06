#!/usr/bin/env python3
"""cron-health-check.py — catch silently-dead cron jobs (the 2026-05-30 churn class).

For every crontab job that writes a `.log`, derive an expected freshness tolerance
from its schedule and check the log's mtime. Stale job -> raise a self-resolving
`system_alerts` row (stable fingerprint, so it dedups instead of accumulating —
unlike the Diag_* detector). Fresh again -> the alert auto-resolves.

Nothing watched the crontab for a week in May/June 2026; this is that watcher.
Schedule: every 30 min from joly's crontab.
"""
import subprocess, re, time, os, sys

NOW = time.time()
# jobs we don't alert on even if quiet (event-driven / only-when-work / noisy)
SKIP = re.compile(r"u112-poll-breakfast|u92-nudge|snag-trigger", re.I)


def crontab_lines():
    r = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if l.strip() and not l.strip().startswith("#")]


def tolerance_min(sched_fields):
    m, h, dom, mon, dow = (sched_fields + ["*"] * 5)[:5]
    def step(f):
        mm = re.match(r"\*/(\d+)$", f)
        return int(mm.group(1)) if mm else None
    if step(m):                       return max(25, 3 * step(m))      # every N min
    if "," in m or m.isdigit():
        if step(h):                   return max(200, 3 * step(h) * 60)  # every N hours
        if dow != "*":                return 9 * 24 * 60                 # weekly
        if dom != "*":                return 40 * 24 * 60                # monthly/quarterly
        return 27 * 60                                                   # daily
    if step(h):                       return max(200, 3 * step(h) * 60)
    return 27 * 60


def main():
    stale, ok = [], []
    for line in crontab_lines():
        mlog = re.search(r">>?\s*(\S+\.log)", line)
        if not mlog:
            continue
        logpath = mlog.group(1)
        mscript = re.search(r"([\w.-]+\.(?:sh|py))", line)
        job = mscript.group(1) if mscript else os.path.basename(logpath)
        if SKIP.search(job):
            continue
        fields = line.split()[:5]
        tol = tolerance_min(fields) * 60
        if not os.path.exists(logpath):
            stale.append((job, "no log file", tol // 60)); continue
        age = NOW - os.path.getmtime(logpath)
        if age > tol:
            stale.append((job, f"{int(age/60)}min stale (tol {tol//60}min)", tol // 60))
        else:
            ok.append(job)

    def psql(sql):
        subprocess.run(["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
                        "-d", "homeai", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)

    # Raise/refresh stale alerts (stable fingerprint per job -> dedups + auto-resolves)
    for job, why, _ in stale:
        fp = "cron_stale_" + re.sub(r"[^a-z0-9]", "_", job.lower())
        summ = f"Cron job {job} appears dead: {why}".replace("'", "''")
        psql(f"""
          INSERT INTO system_alerts (fingerprint, alertname, severity, status,
                                     starts_at, last_updated_at, summary, realm)
          VALUES ('{fp}','CronStale','warning','firing', now(), now(), '{summ}', 'owner')
          ON CONFLICT (fingerprint) DO UPDATE
            SET status='firing', last_updated_at=now(), summary=EXCLUDED.summary,
                acknowledged=false;""")
    # Auto-resolve jobs that are healthy again
    healthy = [re.sub(r"[^a-z0-9]", "_", j.lower()) for j in ok]
    if healthy:
        fps = ",".join("'cron_stale_" + h + "'" for h in healthy)
        psql(f"""UPDATE system_alerts SET status='resolved', last_updated_at=now()
                 WHERE alertname='CronStale' AND status='firing'
                   AND fingerprint IN ({fps});""")

    print(f"cron-health: {len(ok)} fresh, {len(stale)} stale")
    for job, why, _ in stale:
        print(f"  STALE {job}: {why}")
    sys.exit(1 if stale else 0)


if __name__ == "__main__":
    main()
