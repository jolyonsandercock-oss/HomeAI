-- V283: rules-based categorisation push for the 2026 uncategorised residual.
-- Adds vendor_category_rules rows for the top uncategorised 2026 vendors (by count
-- and gross), worked top-down from the live backlog on 2026-07-03. RULES ONLY — no
-- LLM. Applied by scripts/u-invoice-categorise-sweep.sh (the live mechanism); this
-- migration only maintains the rules table.
--
-- Taxonomy anchors (binding, from department taxonomy):
--   bar=drink (Beverage), kitchen=food (Food; Kingfisher/Dole/Caterfood are food
--   suppliers), cafe = J&R MAL125 ONLY, overhead: repairs (Maintenance) /
--   utilities. Flogas + British Gas were mis-filed as Maintenance -> corrected to
--   utilities per taxonomy.
--
-- Platform-forwarded invoices (notification.intuit.com etc): the sweep matches
-- rules against vendor_name for platform domains, so real-vendor rules here use
-- NAME patterns at priority 20 to beat the generic 'intuit' platform rule at
-- priority 50 (which otherwise wins on pattern length -- the flaw that turned
-- Tintagel Brewery beer invoices into 'software'). Same fix bumps the existing
-- tintagel.?brew rule to priority 20.
--
-- Deliberately NOT categorised (ambiguous or not-spend; see overnight report):
-- gmail.com Fwd'd Capital on Tap card statements (not spend), stjosephscornwall
-- (personal school fees, needs realm fix), cakesmiths/cornishcoffee (cafe-vs-
-- kitchen ambiguity), torchfire, ghdirect, aqrsw, boingrapidsecure,
-- gclimoandsons, bopproperty, inn-dispensable, adobesign-forwarded vendors,
-- amazon, hotmail/yahoo individuals, principality (mortgage).
--
-- Reversible: rules snapshot in _backup_categorise_rules_20260703; invoice rows
-- snapshot in _backup_categorise_20260703.

BEGIN;

INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, site, notes) VALUES
  -- ── Food (kitchen suppliers) ─────────────────────────────────────────────
  ('kingfisherbrixham',            'Food',           'Kingfisher Brixham',      60, 'shared', 'V283 fish supplier -> kitchen (taxonomy)'),
  ('dole\.co\.uk',                 'Food',           'Dole',                    60, 'shared', 'V283 produce supplier -> kitchen (taxonomy)'),
  ('caterfood\.co\.uk',            'Food',           'Caterfood',               60, 'shared', 'V283 food wholesaler -> kitchen'),
  ('button.?meats',                'Food',           'Button Meats',            20, 'shared', 'V283 butcher; hotmail.co.uk sender so NAME pattern'),
  -- ── Maintenance / repairs ────────────────────────────────────────────────
  ('ijesltd',                      'Maintenance',    'Ivan Jones Electrical',   60, 'shared', 'V283 electrician'),
  ('gcscsw\.co\.uk',               'Maintenance',    'GCS Cleaning SW',         60, 'shared', 'V283 kitchen canopy/ductwork cleaning'),
  ('boomscaffolding',              'Maintenance',    'Boom Scaffolding',        60, 'shared', 'V283'),
  ('carpigiani',                   'Maintenance',    'Carpigiani',              60, 'shared', 'V283 ice-cream machine service/parts'),
  ('sos-parts',                    'Maintenance',    'SOS Parts',               60, 'shared', 'V283 catering equipment spares'),
  ('welovekeys',                   'Maintenance',    'We Love Keys',            60, 'shared', 'V283 keys/locks'),
  ('drench\.co\.uk',               'Maintenance',    'Drench',                  60, 'shared', 'V283 plumbing/bathroom supplies'),
  ('designer-carpet',              'Maintenance',    'Designer Carpet',         60, 'shared', 'V283 flooring'),
  -- intuit-forwarded real vendors: NAME patterns, priority 20 beats platform rule (50)
  ('rcc.?roofing',                 'Maintenance',    'RCC Roofing',             20, 'shared', 'V283 intuit-forwarded; name match'),
  ('davies.?drainage',             'Maintenance',    'Davies Drainage',         20, 'shared', 'V283 intuit-forwarded; name match'),
  ('south.?west.?drains',          'Maintenance',    'South West Drains',       20, 'shared', 'V283 intuit-forwarded; name match'),
  ('dunmore.?refrigeration',       'Maintenance',    'K Dunmore Refrigeration', 20, 'shared', 'V283 intuit-forwarded; name match'),
  ('arborcare',                    'Maintenance',    'Arborcare Tree Services', 20, 'shared', 'V283 intuit-forwarded; name match'),
  ('tintagel.?skip.?hire',         'Maintenance',    'Tintagel Skip Hire',      20, 'shared', 'V283 xero-forwarded; name match (domain rule cannot see post.xero.com rows)'),
  -- ── Utilities ────────────────────────────────────────────────────────────
  ('loganslogs',                   'utilities',      'Logans Logs',             60, 'shared', 'V283 firewood = heating fuel'),
  -- ── Software / subscriptions ─────────────────────────────────────────────
  ('anthropic\.com',               'Software',       'Anthropic',               60, 'shared', 'V283 Claude subscription'),
  ('kashflow',                     'Software',       'KashFlow',                60, 'shared', 'V283 accounting software'),
  ('hostpresto',                   'Software',       'HostPresto',              60, 'shared', 'V283 web hosting'),
  ('gocardless',                   'Software',       'GoCardless',              60, 'shared', 'V283 payment platform fees'),
  ('\yreplit\y',                   'Software',       'Replit',                  20, 'shared', 'V283 stripe-invoiced; name match'),
  -- ── Income (they pay us) ─────────────────────────────────────────────────
  ('studiolambert',                'Bookings',       'Studio Lambert',          60, 'shared', 'V283 TV contributor fees -> canonical income, not a cost'),
  -- ── Vehicle lease ────────────────────────────────────────────────────────
  ('arval\.co\.uk',                'motoring_lease', 'Arval',                   60, 'shared', 'V283 vehicle leasing'),
  -- ── Overhead / professional / other ──────────────────────────────────────
  ('reghambly',                    'Other',          'Reg Hambly (insurance)',  60, 'shared', 'V283 insurance broker — buildings insurance renewals (NOT a builder; subjects say "Buildings Insurance"/"renewal offer")'),
  ('atcadvisors',                  'Other',          'ATC Advisors',            60, 'shared', 'V283 accountants'),
  ('berrysmith',                   'Other',          'Berry Smith Solicitors',  60, 'shared', 'V283 legal'),
  ('wellabooks',                   'Other',          'Wella Books',             60, 'shared', 'V283 bookkeeping/payroll'),
  ('guildhallchambers',            'Other',          'Guildhall Chambers',      60, 'shared', 'V283 barristers'),
  ('hittraining',                  'Other',          'HIT Training',            60, 'shared', 'V283 apprenticeships/training'),
  ('pplprs',                       'Other',          'PPL PRS',                 60, 'shared', 'V283 music licence'),
  ('bii\.org',                     'Other',          'BII',                     60, 'shared', 'V283 trade membership'),
  ('lambda-tek',                   'Other',          'LambdaTek',               60, 'shared', 'V283 IT hardware'),
  ('stephensons\.com',             'Other',          'Stephensons',             60, 'shared', 'V283 catering equipment/consumables'),
  ('outofeden',                    'Other',          'Out of Eden',             60, 'shared', 'V283 housekeeping/rooms supplies'),
  ('euronetworldwide',             'Other',          'Euronet',                 60, 'shared', 'V283 ATM services'),
  ('wovina\.com',                  'Other',          'Wovina',                  60, 'shared', 'V283 napkins/tableware consumables'),
  ('cornwall\.gov\.uk',            'Other',          'Cornwall Council',        60, 'shared', 'V283 rates/licensing'),
  ('lodgeandthomas',               'Other',          'Lodge & Thomas',          60, 'shared', 'V283 land/estate agents'),
  ('knightleyarchitecture',        'Other',          'Knightley Architecture',  60, 'shared', 'V283 architects'),
  ('cornishprint',                 'Other',          'Cornish Print & Sign',    60, 'shared', 'V283 signage/print'),
  ('mathacademy',                  'Other',          'Math Academy',            60, 'shared', 'V283 personal education subscription'),
  ('cliniko|bucks.?osteopathy',    'Other',          'Bucks Osteopathy',        60, 'shared', 'V283 personal healthcare (Cliniko-invoiced)'),
  ('holidayinnderby',              'Other',          'Holiday Inn Derby',       60, 'shared', 'V283 travel'),
  ('western.?office.?equipment',   'Other',          'Western Office Equipment',20, 'shared', 'V283 intuit-forwarded; name match'),
  ('pickle.?design',               'Other',          'Pickle Design',           20, 'shared', 'V283 intuit-forwarded; name match; design agency')
ON CONFLICT (domain_pattern, site) DO UPDATE SET
  category       = EXCLUDED.category,
  vendor_display = EXCLUDED.vendor_display,
  priority       = EXCLUDED.priority,
  notes          = EXCLUDED.notes;

-- ── Corrections to existing rules ──────────────────────────────────────────
-- Flogas + British Gas are gas suppliers: utilities, not Maintenance (taxonomy).
UPDATE vendor_category_rules SET category='utilities',
  notes=COALESCE(notes,'')||' | V283: Maintenance->utilities per taxonomy'
WHERE domain_pattern IN ('flogas','britishgas') AND site='shared' AND category <> 'utilities';

-- Tintagel Brewery: beat the generic intuit platform rule (priority 50 + longer
-- pattern) so intuit-forwarded beer invoices become Beverage, not software.
UPDATE vendor_category_rules SET priority=20,
  notes=COALESCE(notes,'')||' | V283: priority 50->20 to beat intuit platform rule'
WHERE domain_pattern='tintagel.?brew' AND site='shared' AND priority > 20;

COMMIT;
