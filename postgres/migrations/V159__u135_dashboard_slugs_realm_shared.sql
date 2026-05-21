-- =============================================================================
-- V159 — re-tag dashboard slugs realm=owner → realm=shared
-- =============================================================================
-- U135 T7 turned on realm enforcement in homeai-frontend/lib/db.ts. The
-- default request realm for /app/* is 'work', so any slug still flagged
-- 'owner' returns "refusing to serve to realm=work" and the corresponding
-- dashboard tiles render empty.
--
-- These 15 slugs surface operational inn/pub/cafe data (today's gross,
-- arrivals, rota, invoices, week strip, etc.) — not owner-private finance.
-- Their work-realm siblings (e.g. today_totals, staff_on_rota_today) are
-- already tagged correctly. Re-tagging to 'shared' lets the dashboard
-- render again without weakening the U135 enforcement.
-- =============================================================================

BEGIN;

UPDATE query_whitelist
   SET realm = 'shared'
 WHERE realm = 'owner'
   AND slug IN (
     'ai_cache_effectiveness',
     'dashboard_checkins_today',
     'dashboard_checkouts_today',
     'dashboard_covers_today',
     'dashboard_labour_yesterday',
     'dashboard_special_today',
     'dashboard_week_strip',
     'frontend_accommodation_today',
     'frontend_action_queue',
     'frontend_invoices_recent',
     'frontend_restaurant_today',
     'frontend_rooms_today',
     'frontend_today_gross',
     'frontend_wage_pct_summary',
     'obligations_upcoming'
   );

COMMIT;
