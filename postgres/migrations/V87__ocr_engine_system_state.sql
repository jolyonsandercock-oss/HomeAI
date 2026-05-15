-- =============================================================================
-- V87 — system_state.ocr.engine (U70 T3)
-- =============================================================================
-- Operator-controllable knob for which OCR engine the adapter registry should
-- prefer. Defaults to 'tesseract' (passthrough of Paperless OCR text).
-- Switch by: UPDATE system_state SET value='azure_di' WHERE key='ocr.engine';
-- The registry only honours the value if the corresponding Vault key exists
-- (secret/azure-di or secret/mistral-ocr), else falls back transparently.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

INSERT INTO system_state (key, value, notes, realm)
VALUES ('ocr.engine', 'tesseract',
        'U70 T3 — preferred OCR adapter: tesseract|azure_di|mistral_ocr. '
        'Adapter registry falls back when Vault credentials absent.',
        'owner')
ON CONFLICT (key) DO NOTHING;

COMMIT;
