"""qwen2.5:7b production prompts — outcome of sprint U7 deep-dive optimisation.
Validated composite score: 95.7% (up from 57.5% baseline) on the comprehensive
benchmark suite (email + json + invoice + report). See AGENTS.md for the
full sweep matrix.

The QWEN_OPTIONS dict captures the winning sampling parameters
(temp=0, top_p=0.7, top_k=20-40, format:json). Each task type below has the
prompt template + the system message + a recommended top_k.
"""
from __future__ import annotations

# ─── Sampling defaults (apply to all tasks) ────────────────────
QWEN_OPTIONS = {
    "temperature": 0.0,
    "top_p": 0.7,
    "top_k": 40,           # 20 for classification (tighter), 40 for extraction
}

# ─── System messages ───────────────────────────────────────────
SYS_JSON_ONLY = "You output valid JSON only. No preamble. No markdown."
SYS_CLASSIFY  = "You output JSON only matching the schema. Use only enum values listed."

# ─── Email classification (90% accuracy on 10-sample suite) ────
EMAIL_PROMPT = """Classify a UK pub/property/family email. Output ONLY JSON:
  {{"category": one of [invoice, action-required, report-attachment, school-medical, property, pub, fyi, junk], "entity_id": one of [1, 2, 3, 4]}}

ENTITY HINTS:
  1 = Trading (The Olde Malthouse pub) — brewery, EPOS, food suppliers, accommodation report, premises licence, business rates
  2 = Estates (rental property co.) — gas safety, EICR, tenant matters, letting agents
  3 = Personal — friends, social, junk, spam
  4 = Family/children — school, GP, medical

CATEGORY HINTS — pick the MOST SPECIFIC one:
  - school-medical takes priority over action-required when source is a school OR medical practice
  - property takes priority over action-required when source is property/estates-related (gas, EICR, lettings)
  - invoice/report-attachment take priority over their content's tone

DO NOT invent new category strings. Use ONLY the 8 listed.

Email:
  From: {f}
  Subject: {s}
  Body: {b}
"""

EMAIL_TASK = {
    "system": SYS_CLASSIFY,
    "top_k": 20,           # tighter sampling for classification
    "template": EMAIL_PROMPT,
}

# ─── Invoice extraction (85.4% field accuracy across 5 samples) ──
INVOICE_PROMPT = """Extract supplier-invoice fields. Output ONLY a JSON object with exactly these keys:

{{
  "supplier_name":   <company on the invoice header — Title Case, never null>,
  "invoice_number":  <document reference, e.g. "INV-12345"; "" if truly absent>,
  "invoice_date":    <ISO format YYYY-MM-DD; convert any DD/MM/YYYY in the source>,
  "due_date":        <YYYY-MM-DD or null>,
  "gross_amount":    <total inc VAT, bare number, no £ sign>,
  "net_amount":      <pre-VAT subtotal as bare number, or null if not stated>,
  "vat_amount":      <VAT line as bare number, or null if not stated>,
  "currency":        "GBP",
  "category":        <one of: stock | utilities | rates | services | repairs | insurance | telecoms | professional | other>
}}

Rules:
- Use ISO dates ALWAYS (e.g. "2026-04-15"). Never DD/MM/YYYY or DD-MM-YYYY.
- Bare numerics. No "£", no commas, no quotes around numbers.
- Pick exactly ONE category from the enum above. "Beverage delivery" → stock. "Electricity" → utilities. "Council/business rates" → rates. "Software subscription / accounting" → services.

Text:
{t}
"""

INVOICE_TASK = {
    "system": SYS_JSON_ONLY,
    "top_k": 40,
    "template": INVOICE_PROMPT,
}

# ─── Report parsing (100% field accuracy on 3 samples) ───────────
REPORT_PROMPT = """Extract structured data from this hospitality report.

If the source is an EPOS Z-report, output:
  {{ "report_type": "epos", "report_date": "YYYY-MM-DD", "session": str (Lunch|Dinner|...), "gross": number, "net": number, "vat": number, "covers": int }}

If the source is an ACCOMMODATION report, output:
  {{ "report_type": "accommodation", "report_date": "YYYY-MM-DD", "occupancy_pct": number, "rooms_occupied": int, "total_rooms": int, "adr": number, "revpar": number, "room_revenue": number }}

Output ONLY the JSON, no prose. UK date format DD/MM/YYYY in the source maps to ISO YYYY-MM-DD. Numbers are bare (no £ sign).

Text:
{t}
"""

REPORT_TASK = {
    "system": SYS_JSON_ONLY,
    "top_k": 40,
    "template": REPORT_PROMPT,
}


def build_request(task: dict, *, model: str = "qwen2.5:7b", **format_kwargs) -> dict:
    """Build an Ollama /api/generate body for a given task spec.
    Pass `format_kwargs` to fill the template (e.g. f=, s=, b= for email; t= for extraction)."""
    options = {**QWEN_OPTIONS}
    if "top_k" in task:
        options["top_k"] = task["top_k"]
    return {
        "model": model,
        "prompt": task["template"].format(**format_kwargs),
        "stream": False,
        "format": "json",
        "system": task["system"],
        "options": options,
    }
