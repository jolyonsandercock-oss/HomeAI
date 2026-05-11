# ADR — Dext API removed from Pipeline 2

**Date:** 2026-05-08
**Status:** Accepted (SPEC v5.3 + Sprint 3 mandate)
**Removes:** all references to a Dext API integration

## Context

Earlier SPEC versions assumed Dext exposed a public REST API and treated
Dext as the primary invoice source, with internal pdfplumber+OCR as fallback.
This was incorrect — Dext does not have a documented public API. Building
Pipeline 2 around a non-existent API would have blocked Phase 1 indefinitely
and required us to register for and pay for Dext just to discover the gap.

## Decision

Pipeline 2 (Invoice) uses pdfplumber/MarkItDown + Anthropic Haiku as the
*only* automated extraction path. Dext continues as Jo's manual review tool —
no system integration. For the first 60 days, run both in parallel and
compare outputs manually to validate extraction accuracy.

Spec changes applied in SPEC.md:
- §6.2 Pipeline 2 node sequence rewritten (fetch from Gmail → pdfplumber/MarkItDown → Haiku → INSERT)
- §1.3 source-of-truth list: "Dext = manual review tool only (no API integration)"
- §2.1 Vault: removed `secret/dext` path
- §2.1 n8n-policy: removed `path "secret/data/dext"` capability
- §3.2 invoices: dropped `dext_document_id TEXT` column from spec snippet (init-db.sql still has it as harmless legacy column)
- §6.5 Gate C: removed "Dext priority" test, added "same PDF twice → idempotency" test
- Idempotency key: `invoice_{sha256(supplier_name+gross_amount+invoice_date+entity_id)}` (the `dext_doc_id` variant is gone)

STRETCH-side mirrors:
- §3.3 Vault State: `secret/dext` row marked "Removed 2026-05-08"
- Pending Decisions: "Dext API key" row marked Resolved

## Consequences

**Positive:**
- Pipeline 2 is now buildable and built — `invoice-pipeline-v1` active.
- One fewer external dependency. One fewer credential to rotate.
- The 60-day parallel manual review is an honest accuracy gate — invoices in Xero come from Dext OR our pipeline, with a human comparing at month-end. After 60 days, pick the one with fewer human-review flags.

**Negative:**
- No automatic supplier-side validation against Dext's classification.
- If Dext later opens an API, we'd want to add a *secondary* check (compare extracted fields), but that's a Phase 3+ enhancement.

## References

- Memory: `project_dext_no_api.md`
- SPEC v5.3 §6.2 Pipeline 2
- HOME-AI-STRETCH-v2.0 §3.3 Vault State table
- Implementation: `invoice-pipeline-v1` workflow
