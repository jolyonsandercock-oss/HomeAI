# Metis runbook

Shadow loop runs 06:45 nightly: observe→detect→measure→digest (NO apply).

- **Approve:** set proposal status. `UPDATE cognition.proposals SET status='approved', decided_by='jo', decided_at=now() WHERE id=…;`
- **Reject** (remembers it): INSERT a row into cognition.proposal_rejections with signature md5(detector||':'||entity_ref||':'||action_kind), then set status='rejected'.
- **Enact approved:** `bash scripts/metis-apply.sh` (rule_insert auto; narrow/retire listed for manual SQL).
- **Metrics:** `SELECT run_at, metrics->>'coverage_pct' FROM cognition.task_runs ORDER BY run_at DESC LIMIT 14;`
- **HARD BOUNDARY:** Metis never edits invoice-pipeline files (see spec §6a).
