-- V275: monthly revenue reconciliation guardrail — head_office total vs the OWNER's authoritative
-- figure. This is the only validation that should touch revenue (per the May-31 forensic: per-till
-- data is contaminated; head_office is truth; the owner's monthly report is ground truth).

CREATE TABLE IF NOT EXISTS ops.revenue_truth (
  month        date PRIMARY KEY,            -- first of month
  reported_net numeric NOT NULL,            -- the owner's authoritative net revenue for the month
  note         text,
  recorded_by  text NOT NULL DEFAULT 'jo',
  recorded_at  timestamptz NOT NULL DEFAULT now()
);
-- the one figure we have, penny-exact:
INSERT INTO ops.revenue_truth(month, reported_net, note) VALUES
  ('2026-05-01', 151516.82, 'Jo May-2026 report — penny-exact to head_office')
ON CONFLICT (month) DO NOTHING;

-- helper so anyone (Jo/Claude/Hermes) can record a month's authoritative figure
CREATE OR REPLACE FUNCTION ops.set_revenue_truth(p_month date, p_reported_net numeric, p_note text DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path=ops,public AS $$
  INSERT INTO ops.revenue_truth(month, reported_net, note)
  VALUES (date_trunc('month',p_month)::date, p_reported_net, p_note)
  ON CONFLICT (month) DO UPDATE SET reported_net=EXCLUDED.reported_net, note=EXCLUDED.note, recorded_at=now();
$$;

CREATE OR REPLACE VIEW ops.v_revenue_reconciliation AS
SELECT t.month, t.reported_net,
       round(ho.total, 2) AS head_office_total,
       round(ho.total - t.reported_net, 2) AS variance,
       CASE WHEN ho.total IS NULL THEN 'no_data'
            WHEN abs(ho.total - t.reported_net) <= 1.00 THEN 'reconciled'
            ELSE 'DRIFT' END AS status
FROM ops.revenue_truth t
LEFT JOIN (SELECT date_trunc('month',report_date)::date m, sum(value) total
           FROM touchoffice_department_sales WHERE site='head_office' GROUP BY 1) ho ON ho.m = t.month
ORDER BY t.month;

-- surface reconciliation in live_state so BOTH agents see drift before quoting revenue
CREATE OR REPLACE FUNCTION ops.live_state()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, ops, cognition AS $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('app.current_entity','all',true);
  PERFORM set_config('app.current_realm','owner',true);
  SELECT jsonb_build_object(
    'generated_at', now(),
    'note', 'Single source of live facts. Query this before quoting any number. Raw count(*) lies — use the filtered figures. Revenue: trust head_office only; per-till is contaminated; check revenue_reconciliation.',
    'n8n', jsonb_build_object(
       'active_workflows', (SELECT count(*) FROM workflow_entity WHERE active),
       'master_router_runs_24h', (SELECT count(*) FROM execution_entity e JOIN workflow_entity w ON w.id=e."workflowId"
                                  WHERE w.name='Master Router' AND e."startedAt" > now()-interval '24 hours'),
       'event_bus_live', (SELECT count(*) FROM execution_entity e JOIN workflow_entity w ON w.id=e."workflowId"
                          WHERE w.name='Master Router' AND e."startedAt" > now()-interval '2 hours') > 0),
    'invoices', jsonb_build_object(
       'categorisation_coverage_pct', (SELECT round(100.0*count(*) FILTER (WHERE category_canonical IS NOT NULL)/NULLIF(count(*),0),1)
                                       FROM vendor_invoice_inbox WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),
       'lines_backlog_raw_DO_NOT_USE', (SELECT count(*) FROM vendor_invoice_inbox v WHERE NOT EXISTS(SELECT 1 FROM vendor_invoice_lines l WHERE l.invoice_id=v.id)),
       'lines_backlog_extractable', (SELECT count(*) FROM vendor_invoice_inbox v
              WHERE is_statement=false AND status NOT IN ('duplicate','ignored') AND pdf_fetched_at IS NOT NULL
                AND source_email_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM vendor_invoice_lines l WHERE l.invoice_id=v.id))),
    'revenue_reconciliation', (SELECT jsonb_agg(jsonb_build_object('month',month,'status',status,'variance',variance)) FROM ops.v_revenue_reconciliation),
    'dead_letters_unresolved', (SELECT count(*) FROM dead_letter WHERE NOT resolved),
    'bank_newest_txn', (SELECT max(transaction_date) FROM bank_transactions)
  ) INTO r;
  RETURN r;
END $$;

GRANT SELECT ON ops.revenue_truth, ops.v_revenue_reconciliation TO homeai_readonly, hermes_ro;
GRANT EXECUTE ON FUNCTION ops.set_revenue_truth(date,numeric,text) TO homeai_pipeline;
GRANT EXECUTE ON FUNCTION ops.live_state() TO homeai_readonly, hermes_ro;
