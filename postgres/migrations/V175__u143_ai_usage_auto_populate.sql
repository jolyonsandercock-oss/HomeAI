-- =============================================================================
-- V175 — U143: BEFORE-INSERT trigger to auto-populate cost_gbp, business_priority,
-- and capability_tag on ai_usage rows, so every llm-router INSERT lands ready
-- for the QuotaStatusTile without requiring caller changes.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION home_ai.ai_usage_autopopulate()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- cost_gbp: compute from tokens × model price if missing
    IF NEW.cost_gbp IS NULL THEN
        NEW.cost_gbp := home_ai.compute_ai_cost_gbp(
            NEW.model_used,
            COALESCE(NEW.prompt_tokens, 0),
            COALESCE(NEW.completion_tokens, 0),
            COALESCE(NEW.cache_creation_tokens, 0),
            COALESCE(NEW.cache_read_tokens, 0)
        );
    END IF;

    -- business_priority: derive from task_type
    IF NEW.business_priority IS NULL THEN
        NEW.business_priority := CASE
            WHEN NEW.task_type IN ('invoice_extraction','invoice.extract','invoice.validate',
                                   'bank.categorise','reconciliation.reason','bot.responder',
                                   'compliance.check','cashflow.analyse','legal.analyse')   THEN 'P0'
            WHEN NEW.task_type IN ('email_classifier','email.classify','email.route',
                                   'nanny_classifier','guest.contact_extract',
                                   'digest.generate','report.parse')                          THEN 'P1'
            WHEN NEW.task_type IN ('rag.query','knowledge.lookup')                            THEN 'P2'
            WHEN NEW.task_type IN ('review_drafter','dreaming','news.digest','child.classify') THEN 'P3'
            ELSE NULL
        END;
    END IF;

    -- capability_tag: derive from task_type with a CAP_ prefix
    IF NEW.capability_tag IS NULL THEN
        NEW.capability_tag := CASE NEW.task_type
            WHEN 'invoice_extraction'      THEN 'CAP_INVOICE_EXTRACT'
            WHEN 'invoice.extract'         THEN 'CAP_INVOICE_EXTRACT'
            WHEN 'invoice.validate'        THEN 'CAP_INVOICE_VALIDATE'
            WHEN 'bank.categorise'         THEN 'CAP_BANK_CATEGORISE'
            WHEN 'reconciliation.reason'   THEN 'CAP_RECONCILIATION'
            WHEN 'bot.responder'           THEN 'CAP_BOT_RESPONDER'
            WHEN 'compliance.check'        THEN 'CAP_COMPLIANCE'
            WHEN 'cashflow.analyse'        THEN 'CAP_CASHFLOW'
            WHEN 'legal.analyse'           THEN 'CAP_LEGAL'
            WHEN 'email_classifier'        THEN 'CAP_EMAIL_CLASSIFY'
            WHEN 'email.classify'          THEN 'CAP_EMAIL_CLASSIFY'
            WHEN 'email.route'             THEN 'CAP_EMAIL_ROUTE'
            WHEN 'nanny_classifier'        THEN 'CAP_EMAIL_CLASSIFY'
            WHEN 'guest.contact_extract'   THEN 'CAP_GUEST_CONTACT'
            WHEN 'digest.generate'         THEN 'CAP_DIGEST'
            WHEN 'report.parse'            THEN 'CAP_REPORT_PARSE'
            WHEN 'review_drafter'          THEN 'CAP_REVIEW_DRAFT'
            WHEN 'dreaming'                THEN 'CAP_DREAMING'
            WHEN 'news.digest'             THEN 'CAP_NEWS_DIGEST'
            WHEN 'rag.query'               THEN 'CAP_RAG_QUERY'
            WHEN 'knowledge.lookup'        THEN 'CAP_KNOWLEDGE'
            WHEN 'child.classify'          THEN 'CAP_CHILD_CLASSIFY'
            ELSE NULL
        END;
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_ai_usage_autopopulate ON ai_usage;
CREATE TRIGGER trg_ai_usage_autopopulate
  BEFORE INSERT ON ai_usage
  FOR EACH ROW EXECUTE FUNCTION home_ai.ai_usage_autopopulate();

COMMIT;
