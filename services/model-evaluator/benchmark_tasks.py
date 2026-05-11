"""Benchmark task definitions for the model evaluator.

Per SPEC §6a.4, every benchmark task maps to a real production pipeline
prompt. Same inputs, same scoring rubric as production.

This module is a *suite* — actual execution lives in the model-evaluator
service. Suite ships separately so it can be reviewed/edited without
restarting the service.

Per-task scoring:
  - exact_match: candidate output JSON matches expected exactly (after
    canonicalisation). Returns 1.0 / 0.0.
  - json_validity: candidate output is parseable JSON. Returns 1.0 / 0.0.
  - per_field_accuracy: average of (1 if field matches expected else 0)
    across all expected fields. Returns 0.0..1.0.
  - tokens_per_second: throughput from llm-router timing.
  - manual: not auto-scorable; output goes to benchmark_results.raw_output
    and Jo enters a 1-5 rating via the dashboard.

Composite score = 0.65 * mean(accuracy_tasks) + 0.35 * speed_task_score
where speed_task_score is normalised to 0..1 against a per-tier reference
throughput (configured in model_registry.tier_speed_target).
"""
from __future__ import annotations

# ─── Tier 1 — Hot (email classification, routing) ──────────────
EMAIL_CLASSIFICATION_SAMPLES = [
    {
        "id": "email_001",
        "from": "St Austell Brewery <accounts@staustellbrewery.co.uk>",
        "subject": "Invoice 2026-04-15 — The Olde Malthouse",
        "body": "Please find attached your invoice for £1,842.50 for delivery on 15 April. Payment terms: 30 days.",
        "expected": {"category": "invoice", "entity_id": 1},
    },
    {
        "id": "email_002",
        "from": "Cornwall Council <admin@cornwall.gov.uk>",
        "subject": "Action required: Premises licence renewal",
        "body": "Your premises licence is due for renewal by 1 June. Please complete the attached form.",
        "expected": {"category": "action-required", "entity_id": 1},
    },
    {
        "id": "email_003",
        "from": "TouchOffice <noreply@touchoffice.net>",
        "subject": "Daily Z report 2026-05-08",
        "body": "Z-report attached. Net £2,341.20, VAT £468.24, Gross £2,809.44.",
        "expected": {"category": "report-attachment", "entity_id": 1},
    },
    {
        "id": "email_004",
        "from": "Tintagel School <admin@tintagelschool.co.uk>",
        "subject": "Parents' evening — 12 May 2026",
        "body": "Reminder: parents' evening Wed 12 May, 17:00–19:00. Slot bookings via the portal.",
        "expected": {"category": "school-medical", "entity_id": 4},
    },
    {
        "id": "email_005",
        "from": "Letting Agent <hello@cornishrentals.co.uk>",
        "subject": "Property 3 — gas safety certificate due",
        "body": "Reminder: 5 Atlantic Road gas safety cert expires 30 June. Booking link below.",
        "expected": {"category": "property", "entity_id": 2},
    },
    {
        "id": "email_006",
        "from": "Caterbook <reports@caterbook.com>",
        "subject": "Daily Performance Report",
        "body": "Occupancy 78%, ADR £92.50, RevPAR £72.15. Yesterday's check-ins 12, check-outs 10.",
        "expected": {"category": "report-attachment", "entity_id": 1},
    },
    {
        "id": "email_007",
        "from": "Spam Sender <ads@bestdeals.example>",
        "subject": "Make £1000/day from your phone",
        "body": "Click here to learn the secret millionaires don't want you to know!!!",
        "expected": {"category": "junk", "entity_id": 3},
    },
    {
        "id": "email_008",
        "from": "Olivia <olivia@friend.example>",
        "subject": "Coffee tomorrow?",
        "body": "Free 11am? Same place as last time. — O",
        "expected": {"category": "fyi", "entity_id": 3},
    },
    {
        "id": "email_009",
        "from": "GP Surgery <admin@tintagelgp.nhs.uk>",
        "subject": "Appointment reminder — Tom Sandercock",
        "body": "Appointment confirmed Friday 14:30 with Dr Smith. Bring NHS card.",
        "expected": {"category": "school-medical", "entity_id": 4},
    },
    {
        "id": "email_010",
        "from": "HMRC <noreply@hmrc.gov.uk>",
        "subject": "VAT return due — Q1 2026",
        "body": "Your VAT return for the period ending 31 March 2026 is due by 7 May.",
        "expected": {"category": "action-required", "entity_id": 1},
    },
]

# JSON-validity tasks — extraction prompts where any valid JSON object
# scoring matches the schema is 1.0; anything else 0.0.
JSON_FORMAT_PROMPTS = [
    "Extract: 'Beer £3.40, Cider £4.10, Wine £6.20'. JSON: {drinks: [{name, price}]}.",
    "Parse: 'Sale of 12 units at £8.50 each'. JSON: {qty: int, unit_price: float, total: float}.",
    "Parse: 'Date 2026-05-08, customer table 4'. JSON: {date: str, table: int}.",
    "Parse: 'Net 100, VAT 20, Gross 120'. JSON: {net: float, vat: float, gross: float}.",
    "Parse: 'Mr Smith arriving Friday for 3 nights'. JSON: {guest: str, arrival: str, nights: int}.",
    "Parse: 'Outstanding balance £450 from Inv-2026-007'. JSON: {invoice_number: str, amount: float}.",
    "Parse: 'Card £820, cash £180, total £1000'. JSON: {card: float, cash: float, total: float}.",
    "Parse: 'Shift 09:00–17:00, Sarah'. JSON: {start: str, end: str, staff: str}.",
    "Parse: 'Booking ref BK1234, party 4, 19:30'. JSON: {ref: str, party: int, time: str}.",
    "Parse: 'Invoice INV-2026-021, supplier Bidfood, £312.40'. JSON: {invoice: str, supplier: str, amount: float}.",
]

# ─── Tier 2 — Medium (invoice + report extraction) ─────────────
INVOICE_EXTRACTION_SAMPLES = [
    {
        "id": "inv_001",
        "text": "ST AUSTELL BREWERY LTD\nInvoice INV-2026-04-1842\nDate: 15/04/2026\nDue: 15/05/2026\nDescription   Qty  Unit  Total\nIPA 22pt cask    8  £85   £680.00\nLager keg        4  £150  £600.00\nSpirits          1  £255  £255.50\nNet £1,535.50\nVAT @ 20% £307.10\nTotal £1,842.60",
        "expected": {
            "supplier_name": "St Austell Brewery", "invoice_number": "INV-2026-04-1842",
            "invoice_date": "2026-04-15", "due_date": "2026-05-15",
            "gross_amount": 1842.60, "net_amount": 1535.50, "vat_amount": 307.10,
            "currency": "GBP", "category": "stock"
        },
    },
    {
        "id": "inv_002",
        "text": "BIDFOOD\nInvoice 21-2026-0517\n08/05/2026\nMixed groceries delivery\nGross £312.40 (VAT incl)",
        "expected": {
            "supplier_name": "Bidfood", "invoice_number": "21-2026-0517",
            "invoice_date": "2026-05-08", "gross_amount": 312.40,
            "currency": "GBP", "category": "stock"
        },
    },
    {
        "id": "inv_003",
        "text": "WESTERN POWER DISTRIBUTION\nElectricity invoice for The Olde Malthouse\nApril 2026 quarter\nReading 04287 → 06912 = 2625 kWh @ £0.32 = £840.00\nVAT £168.00 Total £1008.00\nDue 30 days from 02/05/2026",
        "expected": {
            "supplier_name": "Western Power Distribution",
            "invoice_date": "2026-05-02", "due_date": "2026-06-01",
            "gross_amount": 1008.00, "net_amount": 840.00, "vat_amount": 168.00,
            "currency": "GBP", "category": "utilities"
        },
    },
    {
        "id": "inv_004",
        "text": "CORNWALL COUNCIL — BUSINESS RATES\nProperty: The Olde Malthouse, Tintagel\nInstalment 2 of 10\nAmount due 01/06/2026: £527.00",
        "expected": {
            "supplier_name": "Cornwall Council", "invoice_date": "2026-06-01",
            "gross_amount": 527.00, "currency": "GBP", "category": "rates"
        },
    },
    {
        "id": "inv_005",
        "text": "GoCardless\nDirect debit pull confirmation\nMerchant: Sage Accounting (Annual subscription)\n10/05/2026   £288.00 incl VAT\nNet £240, VAT £48",
        "expected": {
            "supplier_name": "Sage Accounting", "invoice_date": "2026-05-10",
            "gross_amount": 288.00, "net_amount": 240.00, "vat_amount": 48.00,
            "currency": "GBP", "category": "services"
        },
    },
]

REPORT_PARSING_SAMPLES = [
    {
        "id": "epos_001",
        "text": "ICRTouch Z-Report\nDate 08/05/2026 Session: Dinner\nGross £2,809.44\nNet  £2,341.20\nVAT  £468.24\nCovers: 87",
        "expected": {
            "report_type": "epos", "report_date": "2026-05-08", "session": "Dinner",
            "gross": 2809.44, "net": 2341.20, "vat": 468.24, "covers": 87
        },
    },
    {
        "id": "accom_001",
        "text": "Caterbook Daily Report 2026-05-08\nOccupancy 78%\nRooms occupied: 7 of 9\nADR £92.50\nRevPAR £72.15\nRoom revenue £647.50",
        "expected": {
            "report_type": "accommodation", "report_date": "2026-05-08",
            "occupancy_pct": 78.0, "rooms_occupied": 7, "total_rooms": 9,
            "adr": 92.50, "revpar": 72.15, "room_revenue": 647.50
        },
    },
    {
        "id": "epos_002",
        "text": "ICRTouch Z-Report\nDate 08/05/2026 Lunch\nNet £984.20  VAT £196.84  Gross £1,181.04  Covers 41",
        "expected": {
            "report_type": "epos", "report_date": "2026-05-08", "session": "Lunch",
            "gross": 1181.04, "net": 984.20, "vat": 196.84, "covers": 41
        },
    },
]

# ─── Tier 3 — Heavy (digest + reasoning, manual scoring) ───────
DIGEST_SAMPLES = [
    {
        "id": "digest_001",
        "context": {
            "invoices_overdue": [{"supplier":"St Austell Brewery", "gross":1842.60, "due":"2026-05-08"}],
            "bank_flags": [],
            "epos_yesterday": {"gross":2809.44, "covers":87, "session":"Dinner"},
            "accommodation_yesterday": {"occupancy_pct":78, "rooms":7, "revpar":72.15},
            "child_events_urgent": [{"child":"Tom","event_type":"medical_visit","date":"2026-05-10"}],
            "review_queue_count": 3,
            "dead_letters_unresolved": 0
        },
        # No `expected` — manual scoring
    },
]

RECONCILIATION_REASONING_SAMPLES = [
    {
        "id": "recon_001",
        "context": {
            "bank_transaction": {"amount": -1842.50, "description": "DD ST AUSTELL", "date":"2026-05-15"},
            "candidate_invoices": [
                {"id":1, "supplier":"St Austell Brewery", "gross":1842.60, "invoice_date":"2026-04-15"},
                {"id":2, "supplier":"St Austell Brewery", "gross":1842.50, "invoice_date":"2026-03-15"},
            ],
            "user_q": "Which invoice does this DD pay, and is the £0.10 difference expected?"
        },
        # Manual scoring
    },
]

# ─── Speed tasks (synthetic prompts of fixed token sizes) ──────
SPEED_PROMPTS = {
    "hot":    "Classify this email into one of: invoice / action-required / report-attachment / school-medical / property / pub / fyi / junk. Return JSON {category}. Email body: " + ("Lorem ipsum dolor sit amet. " * 8),
    "medium": "Extract the supplier_name, invoice_number, invoice_date, gross_amount from this text. Return JSON. Text: " + ("Lorem ipsum dolor sit amet. " * 25),
    "heavy":  "Generate a daily briefing for a pub owner from this structured payload. " + ("Lorem ipsum dolor sit amet. " * 50),
}

# ─── Suite registry ────────────────────────────────────────────
SUITE = {
    "hot": {
        "email_classification": {"weight": 0.40, "scorer": "exact_match",
                                 "samples": EMAIL_CLASSIFICATION_SAMPLES},
        "json_format":          {"weight": 0.25, "scorer": "json_validity",
                                 "samples": JSON_FORMAT_PROMPTS},
        "speed_hot":            {"weight": 0.35, "scorer": "tokens_per_second",
                                 "prompt": SPEED_PROMPTS["hot"], "target_tps": 60},
    },
    "medium": {
        "invoice_extraction":   {"weight": 0.40, "scorer": "per_field_accuracy",
                                 "samples": INVOICE_EXTRACTION_SAMPLES},
        "report_parsing":       {"weight": 0.35, "scorer": "per_field_accuracy",
                                 "samples": REPORT_PARSING_SAMPLES},
        "speed_medium":         {"weight": 0.25, "scorer": "tokens_per_second",
                                 "prompt": SPEED_PROMPTS["medium"], "target_tps": 30},
    },
    "heavy": {
        "digest_quality":           {"weight": 0.40, "scorer": "manual",
                                     "samples": DIGEST_SAMPLES},
        "reconciliation_reasoning": {"weight": 0.35, "scorer": "manual",
                                     "samples": RECONCILIATION_REASONING_SAMPLES},
        "speed_heavy":              {"weight": 0.25, "scorer": "tokens_per_second",
                                     "prompt": SPEED_PROMPTS["heavy"], "target_tps": 8},
    },
}

DEPLOYMENT_THRESHOLD = 0.03  # 3% composite improvement to deploy a new model
COMPOSITE_ACCURACY_WEIGHT = 0.65
COMPOSITE_SPEED_WEIGHT    = 0.35
