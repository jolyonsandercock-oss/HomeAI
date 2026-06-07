-- V246 — H5 rollout step 1: close the grant gap so build-dashboard can SET ROLE
-- homeai_pipeline (RLS_ENFORCE_SET_ROLE=1) without hitting permission-denied 500s.
--
-- homeai_pipeline is NON-superuser + NON-bypassrls, so RLS (realm_isolation +
-- entity_isolation) STILL enforces row visibility after these grants — table
-- privileges are coarse; RLS is the row boundary. This is the exact config n8n
-- already runs under (it connects AS homeai_pipeline). Audit before: missing
-- SELECT on 59 / INSERT 63 / UPDATE 74 / DELETE 151 public tables + 55 sequences.
--
-- ROLLBACK: set RLS_ENFORCE_SET_ROLE=0 and recreate build-dashboard. Do NOT
-- revoke these grants — n8n connects as homeai_pipeline and depends on them, and
-- they are inert for the dashboard while the flag is off (it connects as the
-- postgres superuser and only SET ROLEs when the flag is on).
BEGIN;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO homeai_pipeline;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO homeai_pipeline;

-- Future tables/sequences created by postgres (migrations) auto-grant to the role.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO homeai_pipeline;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO homeai_pipeline;

COMMIT;
