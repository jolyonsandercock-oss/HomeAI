#!/usr/bin/env python3
"""Deterministic tests for the ladder gate + realm derivation. Run: python3 this."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "projA"))
from ladder import gate, derive_realm

def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    return cond

ok = True

# gate: clean invoice passes
g, r = gate({"is_invoice": True, "vendor_name": "Acme", "invoice_date": "2026-05-01",
             "net": 80.0, "vat": 16.0, "gross": 96.0,
             "lines": [{"line_net": 50.0}, {"line_net": 30.0}]})
ok &= check("clean invoice passes", g and not r)

# gate: net+vat != gross fails
g, r = gate({"is_invoice": True, "vendor_name": "Acme", "invoice_date": "2026-05-01",
             "net": 80.0, "vat": 16.0, "gross": 100.0})
ok &= check("net+vat!=gross fails", (not g) and any("gross" in x for x in r))

# gate: missing field fails
g, r = gate({"is_invoice": True, "vendor_name": "", "invoice_date": None, "gross": 10})
ok &= check("missing fields fail", (not g) and any("missing" in x for x in r))

# gate: non-invoice fails
g, r = gate({"is_invoice": False, "vendor_name": "X", "invoice_date": "2026-05-01", "gross": 5})
ok &= check("non-invoice fails", (not g) and any("invoice" in x for x in r))

# gate: line sum mismatch fails
g, r = gate({"is_invoice": True, "vendor_name": "Acme", "invoice_date": "2026-05-01",
             "net": 80.0, "vat": 16.0, "gross": 96.0, "lines": [{"line_net": 10.0}]})
ok &= check("line-sum mismatch fails", (not g) and any("sum" in x for x in r))

# realm derivation
ok &= check("info->work", derive_realm("info", None) == "work")
ok &= check("jo->personal", derive_realm("jo", None) == "personal")
ok &= check("bot->owner", derive_realm("bot", None) == "owner")
ok &= check("entity1->work", derive_realm(None, 1) == "work")
ok &= check("entity3->personal", derive_realm(None, 3) == "personal")
ok &= check("unknown->owner", derive_realm(None, None) == "owner")

print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
