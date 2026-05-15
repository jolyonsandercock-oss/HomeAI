-- =============================================================================
-- V90 — Recipe seed expansion: top 20 PLUs by 90d volume (U71 T3)
-- =============================================================================
-- We seed RECIPE SKELETONS only — recipe row with name, family, portion_unit
-- — and leave recipe_components empty for items where the ingredient mapping
-- needs Jo's domain knowledge. The v_consumption_vs_purchase view tolerates
-- empty components (it just returns zero for that recipe).
--
-- Why skeletons rather than guessed components: a wrong component spec
-- silently rolls into the wastage calculation and creates phantom waste
-- alerts. Better to surface "this recipe has no components yet" than to
-- pretend we know.
--
-- 18 selected; modifiers (WITH ICE & LEMON, ALL TOGETHER, SKIN IN FRIES,
-- ACCOMODATION, D0GGY) are excluded — they're sub-tags, not menu items.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('work');

INSERT INTO recipes (plu_number, name, menu_section, portion_unit, notes, realm)
SELECT * FROM (VALUES
    ('1',    'Guinness',                 'drinks',    'pint',   'U71 T3 skeleton — components TBD', 'work'),
    ('2',    'Harbour Arctic',           'drinks',    'pint',   'U71 T3 skeleton — components TBD', 'work'),
    ('6',    'Harbour Single Fin',       'drinks',    'pint',   'U71 T3 skeleton — components TBD', 'work'),
    ('15',   'Shandy',                   'drinks',    'pint',   'U71 T3 skeleton — mixed beer/lemonade', 'work'),
    ('101',  'Smirnoff',                 'drinks',    '25ml',   'U71 T3 skeleton — spirits measure',     'work'),
    ('340',  'Pepsi',                    'drinks',    'glass',  'U71 T3 skeleton — components TBD', 'work'),
    ('341',  'Pepsi Max',                'drinks',    'glass',  'U71 T3 skeleton — components TBD', 'work'),
    ('342',  'Lemonade',                 'drinks',    'glass',  'U71 T3 skeleton — components TBD', 'work'),
    ('364',  'Water Bottle',             'drinks',    'each',   'U71 T3 skeleton — purchased glass bottle', 'work'),
    ('729',  'Chicken Burger',           'food',      'plate',  'U71 T3 skeleton — chicken + bun + chips', 'work'),
    ('747',  'Wagyu Burger',             'food',      'plate',  'U71 T3 skeleton — wagyu + brioche + chips', 'work'),
    ('759',  'Spiced Shrimp',            'food',      'plate',  'U71 T3 skeleton — components TBD', 'work'),
    ('775',  'Roast Pork',               'food',      'plate',  'U71 T3 skeleton — pork + sides', 'work'),
    ('813',  'Pork Belly',               'food',      'plate',  'U71 T3 skeleton — components TBD', 'work'),
    ('824',  'Crab Linguine',            'food',      'plate',  'U71 T3 skeleton — crab + pasta', 'work'),
    ('904',  'Skin On Fries',            'side',      'portion','U71 T3 skeleton — components TBD', 'work'),
    ('1042', 'Kiddies',                  'food',      'plate',  'U71 T3 skeleton — kids menu', 'work'),
    ('1101', 'Medium Waffle',            'ice_cream', 'each',   'U71 T3 skeleton — waffle base', 'work'),
    ('1102', 'Single Choc Waffle',       'ice_cream', 'each',   'U71 T3 skeleton — 1 scoop choc + waffle', 'work'),
    ('1103', 'Double Choc Waffle',       'ice_cream', 'each',   'U71 T3 skeleton — 2 scoops choc + waffle', 'work')
) AS v (plu_number, name, menu_section, portion_unit, notes, realm)
WHERE NOT EXISTS (SELECT 1 FROM recipes r WHERE r.plu_number = v.plu_number);

COMMIT;
