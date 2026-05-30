#!/usr/bin/env python3
"""Project A — extraction ladder core (deterministic pieces).

This module holds the parts that need NO model and NO network, so they're unit-
testable in isolation: the validation gate and realm derivation. The tier callers
(local Ollama / Haiku / Sonnet) and the orchestration loop are added in later tasks
and import these.
"""
from __future__ import annotations

# Realm derivation — mirrors SPEC §2.5 (mailbox-of-receipt + entity).
_ACCOUNT_REALM = {
    "info": "work", "admin": "work",
    "jo": "personal", "pounana": "personal",
    "bot": "owner",
}


def derive_realm(account: str | None, entity_id: int | None) -> str:
    """Realm for a captured invoice. Account (source mailbox) wins; entity_id is the
    fallback (1→work, 2/3/4→personal, NULL→owner). Defaults to 'work' if account is
    a known work mailbox and nothing else is known."""
    if account and account.lower() in _ACCOUNT_REALM:
        return _ACCOUNT_REALM[account.lower()]
    if entity_id == 1:
        return "work"
    if entity_id in (2, 3, 4):
        return "personal"
    return "owner"


# Validation gate — the false-positive / missing-field guard. Returns (ok, reasons).
_REQUIRED = ("vendor_name", "invoice_date", "gross")
_MONEY_TOL = 0.02


def _num(v):
    try:
        return float(v) if v is not None and v != "" else None
    except (TypeError, ValueError):
        return None


def gate(rec: dict, tol: float = _MONEY_TOL) -> tuple[bool, list[str]]:
    """Decide whether an extraction is trustworthy enough to auto-accept.
    rec: {is_invoice, vendor_name, invoice_date, net, vat, gross, lines:[{line_net}]}.
    """
    reasons: list[str] = []

    if rec.get("is_invoice") is not True:
        reasons.append("not classified as an invoice")

    for f in _REQUIRED:
        if rec.get(f) in (None, ""):
            reasons.append(f"missing {f}")

    net, vat, gross = _num(rec.get("net")), _num(rec.get("vat")), _num(rec.get("gross"))

    # net + vat == gross
    if net is not None and vat is not None and gross is not None:
        if abs((net + vat) - gross) > tol:
            reasons.append(f"net+vat != gross ({net}+{vat} != {gross})")

    # line items sum to net
    lines = rec.get("lines") or []
    if lines and net is not None:
        line_sum = sum((_num(l.get("line_net")) or 0) for l in lines)
        if abs(line_sum - net) > max(tol, 0.01 * abs(net)):
            reasons.append(f"line_net sum {line_sum:.2f} != net {net:.2f}")

    return (len(reasons) == 0, reasons)
