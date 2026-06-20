-- tests/metis/test_01_schema.sql  — run inside homeai-postgres; asserts and ROLLBACKs
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM information_schema.tables
          WHERE table_schema='cognition'
            AND table_name IN ('task_runs','proposals','proposal_rejections','benchmark_labels')) = 4,
         'expected 4 cognition loop tables';
  ASSERT (SELECT count(*) FROM pg_policies
          WHERE schemaname='cognition' AND tablename='proposals' AND policyname='realm_isolation') = 1,
         'proposals must have realm_isolation policy';
  ASSERT to_regprocedure('cognition.fn_detect_categorise_gaps()') IS NOT NULL,
         'gap detector function must exist';
  ASSERT to_regclass('cognition.v_proposal_queue') IS NOT NULL,
         'proposal queue view must exist';
END $$;
ROLLBACK;
