-- V218 — U234: KPI targets / traffic-light + levers config
--
-- Purpose-built (the existing ops_thresholds is a thin lower-better-only,
-- empty table; this needs direction, tier, levers, source). One row per KPI.
-- Status logic lives in the kpi_dashboard slug:
--   higher_better: value>=green_bound -> green; >=amber_bound -> amber; else red
--   lower_better:  value<=green_bound -> green; <=amber_bound -> amber; else red

CREATE TABLE IF NOT EXISTS kpi_targets (
  kpi_key      text PRIMARY KEY,
  label        text NOT NULL,
  tier         text NOT NULL CHECK (tier IN ('management','operational')),
  unit         text NOT NULL DEFAULT '%',            -- '%','£','ratio','score'
  direction    text NOT NULL CHECK (direction IN ('higher_better','lower_better')),
  green_bound  numeric,                              -- green/amber boundary
  amber_bound  numeric,                              -- amber/red boundary
  window_note  text,                                 -- the period the value covers
  lever_amber  text,                                 -- staff action when amber
  lever_red    text,                                 -- staff action when red
  provisional  boolean NOT NULL DEFAULT false,       -- show accuracy caveat
  sort_order   int NOT NULL DEFAULT 100,
  active       boolean NOT NULL DEFAULT true,
  realm        text NOT NULL DEFAULT 'work',
  updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE kpi_targets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON kpi_targets;
CREATE POLICY realm_isolation ON kpi_targets USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner' THEN true
    WHEN current_setting('app.current_realm', true) = 'work'  THEN realm IN ('work','shared')
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''      THEN true
    ELSE realm = current_setting('app.current_realm', true)
  END
);
GRANT SELECT ON kpi_targets TO homeai_readonly;

-- Seed: buildable-now KPIs with UK pub/inn 2025 benchmarked bounds.
-- Levers are DRAFT — Jo to refine (his operational call).
INSERT INTO kpi_targets (kpi_key,label,tier,unit,direction,green_bound,amber_bound,window_note,lever_amber,lever_red,provisional,sort_order) VALUES
('prime_cost','Prime cost % (COGS+labour)','management','%','lower_better',62,68,'rolling 30d',
  'Watch the two big levers: hold non-urgent orders, check GP on top sellers, trim any over-staffed shift.',
  'COGS+labour above 68% of sales. Cut a shift today, pull slow menu items, freeze discretionary orders, review supplier prices with Jo.',
  true,10),
('labour_pct','Labour cost % of sales','management','%','lower_better',28,33,'rolling 7d',
  'Trim tomorrow''s open shift; push covers (specials, upsell coffee & dessert) to lift the denominator.',
  'Labour above 33% of sales. Send one team member home where safe, cut tomorrow''s roster, and drive covers hard today.',
  true,20),
('food_gp','Food GP %','management','%','higher_better',68,62,'current month',
  'Check portion control + wastage log; review the slowest-moving dishes.',
  'Food GP below 62%. Audit portions + wastage, flag supplier price rises to Jo, pull/repriced loss-making dishes.',
  true,30),
('wet_gp','Wet (drinks) GP %','management','%','higher_better',60,55,'current month',
  'Check measures/spillage and that prices match the till; review the wet stock count.',
  'Wet GP below 55%. Recheck pour measures, line wastage, and till prices; investigate any free/comped drinks.',
  true,40),
('sales_vs_lw','Sales vs last week','management','%','higher_better',0,-10,'last 7d vs prior 7d',
  'Down on last week. Board out front, run the specials, prompt the team to upsell.',
  'More than 10% down on last week. Push promotions, open the garden in fair weather, and chase bookings/walk-ins.',
  false,50),
('cogs_coverage','COGS capture coverage','management','%','higher_better',80,50,'current month',
  'Some supplier invoices not yet captured — chase outstanding bills so GP is trustworthy.',
  'Most COGS not captured this month — GP figures unreliable until invoices are in.',
  false,60),
('cashup_variance','Cash-up variance','operational','£','lower_better',5,20,'latest cash-up',
  'Till is a few pounds out. Recount the float and check the void/refund log.',
  'Till more than £20 out. Recount, check voids/refunds, and escalate to Jo.',
  false,70);
