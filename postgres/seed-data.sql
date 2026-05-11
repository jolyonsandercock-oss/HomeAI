-- ============================================================
-- HOME AI SYSTEM — Static Context Seed Data
-- ============================================================

INSERT INTO static_context (key, entity_id, value) VALUES

('pub.details', 1, '{
  "name": "The Olde Malthouse",
  "address": "Tintagel, North Cornwall",
  "epos": "ICRTouch/TouchOffice Web",
  "booking_system": "Caterbook",
  "supplier_primary": "St Austell Brewery"
}'),

('children.profiles', 4, '[
  {"id": 1, "age": 16, "school_type": "secondary"},
  {"id": 2, "age": 10, "school_type": "primary"},
  {"id": 3, "age": 8, "school_type": "primary"}
]'),

('email.routing', null, '{
  "touchoffice_domains": ["touchoffice.net", "icrtouch.com"],
  "caterbook_domains": ["caterbook.com"]
}'),

('holiday.rules', 1, '{
  "method": "statutory_pro_rata",
  "never_use": "12.07_percent_accrual",
  "statutory_minimum_weeks": 5.6,
  "full_time_days_including_bank_holidays": 28
}'),

('ai.thresholds', null, '{
  "email_classifier":        {"min_confidence": 0.80, "escalate_to": "haiku",  "on_failure": "needs_review"},
  "invoice_extractor":       {"min_confidence": 0.90, "escalate_to": "sonnet", "on_failure": "requires_human"},
  "nanny_classifier":        {"min_confidence": 0.85, "escalate_to": "haiku",  "on_failure": "requires_human"},
  "report_parser":           {"min_confidence": 0.70, "escalate_to": "haiku",  "on_failure": "unknown_type"},
  "reconciliation_explainer":{"min_confidence": 0.75, "escalate_to": null,     "on_failure": "flag_for_manual"}
}'),

('ai.anomaly', null, '{
  "invoice": {"multiplier_threshold": 3.0, "min_history_count": 3, "lookback_months": 6}
}'),

('pipeline.versions', null, '{
  "email_pipeline": "1.0", "invoice_pipeline": "1.0", "bank_pipeline": "1.0",
  "xero_pipeline": "1.0", "epos_pipeline": "1.0", "accommodation_pipeline": "1.0",
  "cashing_up_pipeline": "1.0", "nanny_pipeline": "1.0",
  "report_ingestion_pipeline": "1.0", "digest_pipeline": "1.0",
  "personal_trainer_pipeline": "1.0", "compliance_pipeline": "1.0",
  "hr_pipeline": "1.0", "property_pipeline": "1.0", "diagnostics_pipeline": "1.0"
}'),

('system.limits', null, '{
  "max_batch_events": 10, "processing_lease_minutes": 10,
  "stale_lease_check_minutes": 5, "dead_letter_review_hours": 24,
  "dead_letter_digest_threshold": 5, "api_spend_daily_alert_gbp": 15,
  "api_spend_monthly_target_gbp": 20
}'),

('cashing_up.rules', 1, '{
  "variance_amount_threshold_gbp": 5.00, "variance_pct_threshold": 0.5,
  "epos_wait_max_minutes": 180, "epos_retry_interval_minutes": 30
}'),

('model.tiers', null, '{
  "hot":    "qwen2.5:7b",
  "medium": "phi4:14b",
  "heavy":  "llama3.3:70b"
}'),

('system.state', null, '{"state": "running", "paused_at": null, "paused_reason": null}'),

('whatsapp.blacklist', null, '{
  "numbers": [],
  "mode": "store_raw_only",
  "note": "Add phone numbers in E.164 format. Content from blacklisted numbers stored as hash only."
}'),

('system.flood_thresholds', null, '{
  "default": 10,
  "email_pipeline": 20,
  "personal_trainer_pipeline": 5,
  "digest_pipeline": 3
}'),

('data.tiering', null,
 '{"hot_days":90,"archive_tablespace":"hdd_archive","archive_path":"/mnt/hdd/pg_tablespace"}')

ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
