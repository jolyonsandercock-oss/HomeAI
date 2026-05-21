#!/usr/bin/env python3
"""
Generate 45 variant corpus files (9 per template) from the 5 base templates.
Each variant substitutes names, postcodes, sort codes, account numbers,
phone numbers, and emails — preserves the EXPECT line so the validator
can be run uniformly.

Run once:
    cd scripts/u141-presidio-test-corpus
    python3 generate-variants.py
"""

import re
import os
from pathlib import Path

CORPUS = Path(__file__).parent / "corpus"

# Pools of plausible substitutions.
NAMES = [
    "Adam Moralee", "Charlotte Williams", "James Patel", "Mark Henderson",
    "Sarah Thompson", "Robert Pengelly", "Jolyon Sandercock",
    "Olivia Carter", "Ethan Davies", "Sophie Roberts", "Liam Walker",
    "Emily Johnson", "Noah Mitchell", "Grace Edwards", "Oliver Bennett",
    "Mia Phillips", "Harry Reynolds", "Isla Hughes",
]
POSTCODES = [
    "PL34 0DB", "PL34 0DQ", "TQ12 4DH", "BS3 2BA", "PL32 9TX",
    "EX36 4AT", "TR15 1QN", "PL15 7AB", "BS8 1TH", "EX4 6HQ",
    "PL1 1AA", "PL2 2BB", "EX10 8AB", "BS1 5UH", "TQ1 1AB",
]
SORT_CODES = [
    "20-44-12", "60-11-23", "04-00-04", "60-83-71", "08-92-99",
    "23-14-70", "30-90-87", "40-47-84", "82-99-22", "16-58-10",
]
ACCT_NUMBERS = [
    "87654321", "12345678", "98765432", "55667788", "11223344",
    "22334455", "33445566", "44556677", "66778899", "77889900",
]
PHONES = [
    "07700 900123", "07911 234567", "07700 900456", "07911 567890",
    "07700 900789", "07911 890123",
]
EMAILS = [
    "sarah.thompson@bidvest.co.uk", "mark.henderson@example.com",
    "info@cornwallcooling.co.uk", "james.patel@example.co.uk",
    "payroll@malthousetintagel.com", "supplier@example.co.uk",
    "contact@hopoils.co.uk", "billing@suppliesco.com",
]
NI_NUMBERS = [
    "AB123456C", "JK654321A", "CT112233B", "MR998877D",
    "NP556677A", "RX887766C",
]
VAT_NUMBERS = [
    "GB 123 4567 89", "GB 987654321", "GB 555 1234 67", "GB 444 9876 54",
]


def rotate(seq, i): return seq[i % len(seq)]


def variant_text(template: str, n: int) -> str:
    """Substitute personalised tokens in a template. n is 1..9."""
    s = template
    # Names: replace each occurrence with rotated picks
    name_iter = iter([rotate(NAMES, n * 3 + i) for i in range(6)])
    s = re.sub(
        r"(Sarah Thompson|Mark Henderson|James Patel|Charlotte Williams|Robert Pengelly|Jolyon Sandercock)",
        lambda m: next(name_iter, "Alex Brown"),
        s,
    )
    # Postcodes
    pc_iter = iter([rotate(POSTCODES, n * 2 + i) for i in range(4)])
    s = re.sub(
        r"\b(PL34 0DB|PL34 0DQ|TQ12 4DH|BS3 2BA|PL32 9TX)\b",
        lambda m: next(pc_iter, "PL1 1AA"),
        s,
    )
    # Sort codes
    sc_iter = iter([rotate(SORT_CODES, n + i) for i in range(3)])
    s = re.sub(r"\b\d{2}-\d{2}-\d{2}\b", lambda m: next(sc_iter, "00-00-00"), s)
    # Account numbers
    an_iter = iter([rotate(ACCT_NUMBERS, n + i) for i in range(3)])
    s = re.sub(r"\b\d{8}\b", lambda m: next(an_iter, "00000000"), s)
    # Phones
    ph_iter = iter([rotate(PHONES, n + i) for i in range(2)])
    s = re.sub(r"\b07[79]\d{2}\s?\d{6}\b", lambda m: next(ph_iter, "07700 000000"), s)
    # Emails
    em_iter = iter([rotate(EMAILS, n + i) for i in range(2)])
    s = re.sub(
        r"\b[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9-.]+\b",
        lambda m: next(em_iter, "test@example.com"),
        s,
    )
    # NI numbers
    s = re.sub(r"\b[A-Z]{2}\d{6}[A-D]\b", rotate(NI_NUMBERS, n), s)
    # VAT (GB + digits)
    vat_iter = iter([rotate(VAT_NUMBERS, n + i) for i in range(2)])
    s = re.sub(r"\bGB\s?\d{3}\s?\d{3,4}\s?\d{2,3}\b", lambda m: next(vat_iter, "GB 111 1111 11"), s)
    return s


def main():
    base_files = sorted(CORPUS.glob("*-01.txt"))
    if len(base_files) != 5:
        raise SystemExit(f"expected 5 base files, found {len(base_files)}")

    for base in base_files:
        template = base.read_text()
        prefix = base.name.rsplit("-", 1)[0]  # e.g. '01-hospitality-invoice'
        for i in range(2, 11):                # 02..10 → 9 variants
            out = CORPUS / f"{prefix}-{i:02d}.txt"
            out.write_text(variant_text(template, i))
            print(f"wrote {out.name}")

    total = len(list(CORPUS.glob("*.txt")))
    print(f"\nCorpus size: {total} files")


if __name__ == "__main__":
    main()
