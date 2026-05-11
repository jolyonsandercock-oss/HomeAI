-- V11: import_bank_transactions(bank_account_id, rows) — Pipeline 4 helper.
--
-- Looks up the bank account's entity, sets RLS context, then bulk-inserts the
-- supplied rows with idempotency_key = bank_<sha256(account+date+amount+desc[:50])>.
-- Returns a single-row summary suitable for the bank.imported event payload.
--
-- bank_transactions has a UNIQUE constraint on idempotency_key, so ON CONFLICT
-- works here (unlike events, where partitioning blocks the unique index).
-- Fail closed: unknown bank_account_id raises rather than auto-creating.

CREATE OR REPLACE FUNCTION import_bank_transactions(
  p_bank_account_id INT,
  p_rows            JSONB
)
RETURNS TABLE(
  bank_account_id INT,
  entity_id       INT,
  rows_received   INT,
  rows_inserted   INT,
  date_min        DATE,
  date_max        DATE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_entity_id INT;
BEGIN
  SELECT ba.entity_id INTO v_entity_id
    FROM bank_accounts ba
   WHERE ba.id = p_bank_account_id;

  IF v_entity_id IS NULL THEN
    RAISE EXCEPTION 'unknown bank_account_id: %', p_bank_account_id;
  END IF;

  PERFORM set_config('app.current_entity', v_entity_id::text, true);

  RETURN QUERY
  WITH input AS (
    SELECT * FROM jsonb_to_recordset(p_rows) AS x(
      transaction_date date,
      amount           numeric,
      description      text,
      reference        text,
      balance          numeric
    )
  ),
  prepared AS (
    SELECT
      'bank_' || encode(digest(
        p_bank_account_id::text || ':' ||
        i.transaction_date::text || ':' ||
        i.amount::text          || ':' ||
        left(coalesce(i.description, ''), 50),
        'sha256'
      ), 'hex') AS idempotency_key,
      i.transaction_date, i.amount, i.description, i.reference, i.balance
    FROM input i
  ),
  inserted AS (
    INSERT INTO bank_transactions
      (idempotency_key, bank_account_id, entity_id, transaction_date,
       description, amount, balance, reference, source)
    SELECT pr.idempotency_key, p_bank_account_id, v_entity_id,
           pr.transaction_date, pr.description, pr.amount,
           pr.balance, pr.reference, 'csv_upload'
      FROM prepared pr
     ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING transaction_date
  )
  SELECT
    p_bank_account_id                     AS bank_account_id,
    v_entity_id                           AS entity_id,
    (SELECT count(*)::int FROM input)     AS rows_received,
    (SELECT count(*)::int FROM inserted)  AS rows_inserted,
    (SELECT min(transaction_date) FROM inserted) AS date_min,
    (SELECT max(transaction_date) FROM inserted) AS date_max;
END;
$fn$;

GRANT EXECUTE ON FUNCTION import_bank_transactions(INT, JSONB) TO homeai_pipeline;
