-- V271: ops.live_state() — the single, generated source of LIVE FACTS both AI agents query
-- before quoting any number (Pillar 1 of the multi-agent-coherence design). Returns the exact
-- facts that were gotten wrong this session: is-n8n-live, invoice coverage, the FILTERED
-- extractable backlog (not raw count(*)), unresolved dead-letters, bank freshness. SECURITY
-- DEFINER + sets GUCs so any caller (hermes_ro, readonly) gets the same answer.
CREATE OR REPLACE FUNCTION ops.live_state()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, ops, cognition AS $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('app.current_entity','all',true);
  PERFORM set_config('app.current_realm','owner',true);
  SELECT jsonb_build_object(
    'generated_at', now(),
    'note', 'Single source of live facts. Query this before quoting any number. Raw count(*) lies — use the filtered figures here.',
    'n8n', jsonb_build_object(
       'active_workflows', (SELECT count(*) FROM workflow_entity WHERE active),
       'master_router_runs_24h', (SELECT count(*) FROM execution_entity e JOIN workflow_entity w ON w.id=e."workflowId"
                                  WHERE w.name='Master Router' AND e."startedAt" > now()-interval '24 hours'),
       'event_bus_live', (SELECT count(*) FROM execution_entity e JOIN workflow_entity w ON w.id=e."workflowId"
                          WHERE w.name='Master Router' AND e."startedAt" > now()-interval '2 hours') > 0),
    'invoices', jsonb_build_object(
       'categorisation_coverage_pct', (SELECT round(100.0*count(*) FILTER (WHERE category_canonical IS NOT NULL)/NULLIF(count(*),0),1)
                                       FROM vendor_invoice_inbox WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),
       'uncategorised_gbp_ytd', (SELECT round(sum(COALESCE(net_amount,gross_amount,0)))
                                 FROM vendor_invoice_inbox WHERE is_statement=false AND status NOT IN ('duplicate','ignored')
                                   AND category_canonical IS NULL AND COALESCE(invoice_date,received_at::date) >= date_trunc('year',CURRENT_DATE)),
       'lines_backlog_raw_DO_NOT_USE', (SELECT count(*) FROM vendor_invoice_inbox v WHERE NOT EXISTS(SELECT 1 FROM vendor_invoice_lines l WHERE l.invoice_id=v.id)),
       'lines_backlog_extractable', (SELECT count(*) FROM vendor_invoice_inbox v
              WHERE is_statement=false AND status NOT IN ('duplicate','ignored') AND pdf_fetched_at IS NOT NULL
                AND source_email_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM vendor_invoice_lines l WHERE l.invoice_id=v.id)),
       'invoices_with_lines', (SELECT count(DISTINCT invoice_id) FROM vendor_invoice_lines)),
    'dead_letters_unresolved', (SELECT count(*) FROM dead_letter WHERE NOT resolved),
    'bank_newest_txn', (SELECT max(transaction_date) FROM bank_transactions),
    'pipelines_registered', (SELECT count(*) FROM ops.pipeline_registry WHERE enabled),
    'pipeline_runs_24h', (SELECT count(*) FROM ops.pipeline_runs WHERE finished_at > now()-interval '24 hours')
  ) INTO r;
  RETURN r;
END $$;

GRANT EXECUTE ON FUNCTION ops.live_state() TO homeai_readonly, homeai_pipeline;
COMMENT ON FUNCTION ops.live_state() IS 'Pillar 1: single source of live facts for all AI agents. SELECT ops.live_state() before quoting any number.';
