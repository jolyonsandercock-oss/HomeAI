-- V216 — U147 Phase A: make invoice/COGS views honour RLS
--
-- Root cause (U147 Bug A, part 2): these views are owned by `postgres`
-- (a BYPASSRLS superuser) and were created without `security_invoker`, so
-- SELECTs through them evaluate RLS as the *view owner* — i.e. RLS on the
-- underlying realm-aware tables (purchases, purchase_lines) is bypassed. The
-- `:realm` SQL param then becomes the only realm filter, so a work-realm
-- request that passes `:realm='personal'` (via the /invoices realm toggle)
-- returns personal invoices. Demonstrated: purchase_kpis?realm=personal
-- returned 65 personal invoices / £62k over a work request.
--
-- Fix: set security_invoker=true so the view runs RLS as the *calling* role
-- (homeai_readonly) with whatever app.current_realm the request pinned. Paired
-- with the frontend transaction-wrapping fix (lib/db.ts withRealm) that makes
-- set_realm actually persist for the query, a work request is now capped to
-- work+shared rows before the :realm filter is applied.
--
-- Safe: homeai_readonly already holds SELECT on purchases / purchase_lines,
-- so reads continue to work; they are now simply RLS-filtered.
--
-- NOTE (follow-up, tracked in .claude/sprints/U147-rls-role-split-rollout.md):
-- a full audit of the view layer is still owed — every other postgres-owned
-- view over a realm-aware table has the same BYPASSRLS property. v_cogs_period
-- and v_gross_margin_period happen to hardcode realm='work' internally so they
-- don't leak, but are flipped here too for consistency. v_invoice_lines_resolved
-- (vendor_invoice_* tables) and v_daily_gp are deferred to that audit.

ALTER VIEW v_purchase_search     SET (security_invoker = true);
ALTER VIEW v_cogs_period         SET (security_invoker = true);
ALTER VIEW v_gross_margin_period SET (security_invoker = true);
