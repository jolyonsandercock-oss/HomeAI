-- =============================================================================
-- V172 — U143: backfill business_priority + capability_tag on ai_usage.
-- =============================================================================
-- Until llm-router is refactored (U142) to write business_priority directly,
-- the existing 241 ai_usage rows have NULL priority and the QuotaStatusTile
-- shows £0 across all tiers. Mapping task_type → priority lets the tile
-- surface real spend immediately.
--
-- Task-type → tier mapping:
--   P0 (financial)        invoice_extraction, bot.responder
--   P1 (email/compliance) email_classifier, email.classify, nanny_classifier,
--                         guest.contact_extract
--   P2 (RAG)              (none yet)
--   P3 (research)         review_drafter, dreaming
--
-- Task-type → capability_tag is a 1:1 map for now; LiteLLM will set this
-- field per-call once U142 lands.
-- =============================================================================

BEGIN;

UPDATE ai_usage SET
  business_priority = CASE task_type
    WHEN 'invoice_extraction'   THEN 'P0'
    WHEN 'bot.responder'        THEN 'P0'
    WHEN 'email_classifier'     THEN 'P1'
    WHEN 'email.classify'       THEN 'P1'
    WHEN 'nanny_classifier'     THEN 'P1'
    WHEN 'guest.contact_extract' THEN 'P1'
    WHEN 'review_drafter'       THEN 'P3'
    WHEN 'dreaming'             THEN 'P3'
    ELSE NULL
  END,
  capability_tag = CASE task_type
    WHEN 'invoice_extraction'   THEN 'CAP_INVOICE_EXTRACT'
    WHEN 'bot.responder'        THEN 'CAP_BOT_RESPONDER'
    WHEN 'email_classifier'     THEN 'CAP_EMAIL_CLASSIFY'
    WHEN 'email.classify'       THEN 'CAP_EMAIL_CLASSIFY'
    WHEN 'nanny_classifier'     THEN 'CAP_EMAIL_CLASSIFY'
    WHEN 'guest.contact_extract' THEN 'CAP_GUEST_CONTACT'
    WHEN 'review_drafter'       THEN 'CAP_REVIEW_DRAFT'
    WHEN 'dreaming'             THEN 'CAP_DREAMING'
    ELSE NULL
  END
WHERE business_priority IS NULL;

COMMIT;
