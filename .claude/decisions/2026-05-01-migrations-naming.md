# 2026-05-01 — Migration file naming convention

## Context

Up to now, the PostgreSQL schema has been built once at first boot via
Docker's `/docker-entrypoint-initdb.d` mechanism, which executes
`postgres/init-db.sql`, `rls-policies.sql`, and `seed-data.sql` exactly
once on an empty data directory. There has been no concept of versioned
schema changes — any post-init alteration was ad hoc.

Tonight's Metabase fix required a structured schema change after the DB
was already populated, forcing the question: how do we version
migrations going forward?

## Options considered

- **(A) Flyway-style `V_n__name.sql` files under `postgres/migrations/`,
  applied manually via `psql -f`.** Lightweight; no tool dependency;
  filename ordering encodes intent.
- **(B) Adopt Atlas (`atlas.hcl` + baseline V1 from current schema).**
  Properly tool-enforced versioning. Requires installing Atlas, writing
  the config, and producing a V1 baseline that round-trips against the
  existing init scripts. ~1 day of work.
- **(C) No naming convention; ad-hoc `.sql` files.** Lowest ceremony;
  no future-proofing.

## Decision

**(A) Flyway-style `V_n__name.sql` under `postgres/migrations/`.**
First file created tonight: `V2__metabase_db.sql`.

No `V1__` baseline file exists; the schema in `init-db.sql` remains the
de facto V1. Future migrations start at V2 and increment.

Migrations are applied **manually** by the operator with
`docker exec -i homeai-postgres psql -U postgres -f - < <file>` and any
required `-v var=value` substitutions. There is no automatic runner.

## Why not (B)

Atlas is the right answer eventually, but introducing it tonight was
out of scope for unblocking Metabase. The naming convention chosen
here is forward-compatible with Atlas — when we adopt Atlas in a later
phase, existing `V_n__*.sql` files can be reformatted into the Atlas
directory layout without renaming.

## Why not (C)

The `V_n__` prefix is cheap, gives unambiguous ordering, and is the
single most-recognisable migration convention across the SQL ecosystem
— no future operator (or Claude session) will be confused by it.

## Consequences

- Every schema change after first boot **must** be a `V_n__` file in
  `postgres/migrations/`. Direct `psql` ALTER statements in chat are
  not acceptable — they leave no audit trail.
- Migrations must be **idempotent** (use `IF NOT EXISTS`,
  `WHERE NOT EXISTS … \gexec`, etc.) so partial failures can be
  re-run safely.
- Applied-version tracking is currently informal (filename in commit
  history). When this becomes a problem, add a `schema_migrations`
  table — that's the trigger for revisiting (B).

## Status

Active. Revisit when the migrations directory has 5+ files or when
multi-environment promotion (dev / staging / prod) becomes a concern.
