# Realm & entity isolation — how data separation works end-to-end

Two orthogonal axes on (almost) every table:

**Entity** = legal owner. 1 = pub/inn Ltd (work), 2 = property Ltd (ARE),
3 = personal/family, 4 = joint. **Realm** = visibility surface: `work`,
`personal`, `shared`, plus `owner` as a *viewing* level (sees everything).
Realm derives from entity via `realm_from_entity_id()` and a global invariant
holds: `realm = realm_from_entity_id(entity_id)` wherever entity is set
(V260/V266 enforce + assert it; an INSERT trigger on bank_transactions derives
entity from bank_accounts, then realm from entity — trigger names sort
alphabetically so entity fires first).

Enforcement is Postgres RLS driven by two GUCs set per-connection/transaction:
`app.current_entity` ('1'..'n' or 'all') and `app.current_realm`. Policies come
in two flavours: `entity_isolation` is **PERMISSIVE** — rows with NULL
entity_id silently vanish from entity-scoped queries (the V260 defect class:
2,286 invisible bank rows), and `realm_isolation` is **RESTRICTIVE** (owner →
true; work → work+shared; personal → personal+shared). Gotchas that follow
from this design: Postgres does NOT short-circuit OR (guard casts with CASE);
`SET ROLE` drops GUC defaults (set both GUCs explicitly); a missing entity GUC
= silent empty results, not an error.

Realm flips on existing rows are deliberately hard: a trigger rejects them
unless `app.realm_override_active='1'` is set transaction-locally, and every
bulk override writes an audit_log row (V164 pattern). Frontend reads go
through `withRealm()` which pins the realm GUC for the WHOLE transaction
(SET LOCAL semantics — splitting it across autocommit statements re-opens the
U147 cross-realm leak). The Authelia `Remote-Groups` header is the only
trusted realm source for web requests; client input never is.
