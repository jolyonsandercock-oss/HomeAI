-- V205 / U228 T4 — vault seal state snapshot table.
-- vault-watchdog.sh writes the current state on each 5-min tick;
-- the `vault_status` mcp slug reads from here for Mission Control.
--
-- Single-row table by design (id=1 always); we update in place rather
-- than appending history (vault-watchdog already stores transitions in
-- /var/lib/vault-watchdog/last-state, and audit_log captures pages sent).

BEGIN;

CREATE TABLE IF NOT EXISTS vault_seal_state (
  id              smallint     PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  state           text         NOT NULL,                  -- 'sealed' | 'unsealed' | 'down' | 'unknown'
  checked_at      timestamptz  NOT NULL DEFAULT now(),
  last_change_at  timestamptz,                            -- when state last differed from previous
  prev_state      text,                                   -- for the transition message
  realm           text         NOT NULL DEFAULT 'work'
);

-- Seed row so the slug always returns one row (unknown until first watchdog tick).
INSERT INTO vault_seal_state (id, state, checked_at)
VALUES (1, 'unknown', now())
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE  vault_seal_state IS
  'Single-row snapshot of homeai-vault seal status, written by vault-watchdog every 5 min.';

COMMIT;
