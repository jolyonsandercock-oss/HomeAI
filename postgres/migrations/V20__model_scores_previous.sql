-- V20: previous_* columns on model_scores so the leaderboard can render
-- before/after deltas (e.g. format:json optimisation impact).
--
-- Pattern: a BEFORE UPDATE trigger captures the row's OLD composite/accuracy/
-- speed/format scores into matching previous_* columns, but ONLY when the
-- score actually changes. ON CONFLICT … DO UPDATE in the writer fires this
-- trigger naturally — no application-side changes required.

\set ON_ERROR_STOP on

ALTER TABLE model_scores
  ADD COLUMN IF NOT EXISTS previous_composite_score numeric(5,2),
  ADD COLUMN IF NOT EXISTS previous_accuracy_score  numeric(5,2),
  ADD COLUMN IF NOT EXISTS previous_speed_score     numeric(5,2),
  ADD COLUMN IF NOT EXISTS previous_format_score    numeric(5,2),
  ADD COLUMN IF NOT EXISTS previous_scored_at       timestamptz;

CREATE OR REPLACE FUNCTION model_scores_capture_previous()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
  -- Only carry previous values when the composite changes — avoids losing
  -- the prior baseline on incidental UPDATEs that don't reflect a re-run.
  IF NEW.composite_score IS DISTINCT FROM OLD.composite_score THEN
    NEW.previous_composite_score := OLD.composite_score;
    NEW.previous_accuracy_score  := OLD.accuracy_score;
    NEW.previous_speed_score     := OLD.speed_score;
    NEW.previous_format_score    := OLD.format_score;
    NEW.previous_scored_at       := OLD.scored_at;
  END IF;
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS trg_model_scores_capture_previous ON model_scores;
CREATE TRIGGER trg_model_scores_capture_previous
  BEFORE UPDATE ON model_scores
  FOR EACH ROW
  EXECUTE FUNCTION model_scores_capture_previous();

-- Backfill: phi4:14b ran in sprint U5 (medium tier, format:off) at composite
-- 49.2%. Insert that as a historical baseline so the dashboard can show the
-- delta once the next sweep produces the format:json result.
INSERT INTO model_scores
  (model_name, tier, score_date,
   composite_score, accuracy_score, speed_score, format_score,
   avg_speed_tps, avg_latency_ms, task_count, scored_at)
VALUES
  ('phi4:14b', 'medium', DATE '2026-05-08',
   49.2, 50.0,  76.0, 20.0,
   22.8, 4500, 28, '2026-05-09 01:51:58+00')
ON CONFLICT (model_name, tier, score_date) DO NOTHING;

SELECT 'model_scores extended' AS check,
       count(*)::text || ' rows' AS detail
  FROM model_scores;
