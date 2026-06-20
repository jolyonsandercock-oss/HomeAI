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

  -- realm_isolation policy exists on all four loop tables
  ASSERT (SELECT count(*) FROM pg_policies
          WHERE schemaname='cognition' AND policyname='realm_isolation'
            AND tablename IN ('task_runs','proposals','proposal_rejections','benchmark_labels')) = 4,
         'realm_isolation policy must exist on all 4 loop tables';

  -- composite type exists
  ASSERT to_regtype('cognition.detection') IS NOT NULL,
         'composite type cognition.detection must exist';

  -- all four detector functions exist
  ASSERT to_regprocedure('cognition.fn_detect_categorise_gaps()') IS NOT NULL,
         'fn_detect_categorise_gaps() must exist';
  ASSERT to_regprocedure('cognition.fn_detect_categorise_contradictions()') IS NOT NULL,
         'fn_detect_categorise_contradictions() must exist';
  ASSERT to_regprocedure('cognition.fn_detect_categorise_corrections()') IS NOT NULL,
         'fn_detect_categorise_corrections() must exist';
  ASSERT to_regprocedure('cognition.fn_detect_categorise_overbroad(integer)') IS NOT NULL,
         'fn_detect_categorise_overbroad(integer) must exist';

  -- proposals dedup UNIQUE constraint exists
  ASSERT (SELECT count(*) FROM pg_constraint
          WHERE conrelid='cognition.proposals'::regclass AND contype='u') >= 1,
         'proposals table must have at least one UNIQUE constraint (dedup guard)';
END $$;
ROLLBACK;
