-- V223 — U234: Jo's real KPI thresholds (replacing benchmarked defaults).
UPDATE kpi_targets SET green_bound=28, amber_bound=30 WHERE kpi_key='labour_pct';
UPDATE kpi_targets SET green_bound=75, amber_bound=70 WHERE kpi_key='food_gp';
UPDATE kpi_targets SET green_bound=69, amber_bound=72 WHERE kpi_key='prime_cost';
UPDATE kpi_targets SET green_bound=65, amber_bound=60 WHERE kpi_key='wet_gp';
