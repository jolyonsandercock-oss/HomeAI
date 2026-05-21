"""
Custom UK recognizers for Presidio.

Adds high-precision regex recognizers for UK-specific PII not covered well
by Presidio's defaults (which lean US):

  UK_POSTCODE         — full UK postcodes, e.g. PL34 0DB
  UK_SORT_CODE        — bank sort codes, e.g. 12-34-56
  UK_ACCOUNT_NUMBER   — 8-digit account numbers, with light context filter
  UK_NI_NUMBER        — National Insurance numbers, e.g. AB123456C
  UK_VAT_NUMBER       — VAT registration numbers (GB123456789 or 123456789)
  XERO_CONTACT_ID     — Xero contact GUIDs loaded from xero_contacts at boot
                         (NOT in this file — loaded dynamically by main.py)
"""

from presidio_analyzer import PatternRecognizer, Pattern


# ----- UK_POSTCODE ---------------------------------------------------------
# Format: A[A]9[A|9] 9AA (one or two letters, digit, optional letter/digit,
# space, digit, two letters). Allow optional space.
UK_POSTCODE_PATTERN = Pattern(
    name="uk_postcode_full",
    regex=r"\b[A-Z]{1,2}\d[A-Z\d]?\s?\d[A-Z]{2}\b",
    score=0.95,
)
uk_postcode = PatternRecognizer(
    supported_entity="UK_POSTCODE",
    patterns=[UK_POSTCODE_PATTERN],
    context=["postcode", "post code", "post-code", "zip", "address"],
)


# ----- UK_SORT_CODE --------------------------------------------------------
# Format: 99-99-99 (six digits, hyphen-separated)
UK_SORT_CODE_PATTERN = Pattern(
    name="uk_sort_code_hyphen",
    regex=r"\b\d{2}-\d{2}-\d{2}\b",
    score=0.9,
)
uk_sort_code = PatternRecognizer(
    supported_entity="UK_SORT_CODE",
    patterns=[UK_SORT_CODE_PATTERN],
    context=["sort", "sort code", "sortcode", "bank"],
)


# ----- UK_ACCOUNT_NUMBER ---------------------------------------------------
# 8 digits. Without context the precision is mediocre (any 8-digit number
# matches), so we require account-related context for the high score.
UK_ACCOUNT_NUMBER_PATTERN = Pattern(
    name="uk_account_8d",
    regex=r"\b\d{8}\b",
    score=0.4,  # low base; context boosts
)
uk_account_number = PatternRecognizer(
    supported_entity="UK_ACCOUNT_NUMBER",
    patterns=[UK_ACCOUNT_NUMBER_PATTERN],
    context=["account", "account number", "account no", "a/c", "acct"],
)


# ----- UK_NI_NUMBER --------------------------------------------------------
# Format: 2 letters (not D, F, I, Q, U, V) + 6 digits + 1 suffix letter (A-D)
# Allow optional spaces between blocks (people write them with spaces).
UK_NI_NUMBER_PATTERN = Pattern(
    name="uk_ni_number",
    regex=r"\b(?!BG|GB|NK|KN|TN|NT|ZZ)[A-CEGHJ-PR-TW-Z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b",
    score=0.92,
)
uk_ni_number = PatternRecognizer(
    supported_entity="UK_NI_NUMBER",
    patterns=[UK_NI_NUMBER_PATTERN],
    context=["national insurance", "ni number", "ni no", "nino"],
)


# ----- UK_VAT_NUMBER -------------------------------------------------------
# Format: optional 'GB' + 9 digits, sometimes with a 3-digit branch suffix.
UK_VAT_NUMBER_PATTERN = Pattern(
    name="uk_vat",
    regex=r"\b(?:GB)?\s?\d{3}\s?\d{4}\s?\d{2}(?:\s?\d{3})?\b",
    score=0.5,
)
uk_vat_number = PatternRecognizer(
    supported_entity="UK_VAT_NUMBER",
    patterns=[UK_VAT_NUMBER_PATTERN],
    context=["vat", "vat number", "vat no", "vat registration"],
)


CUSTOM_RECOGNIZERS = [
    uk_postcode,
    uk_sort_code,
    uk_account_number,
    uk_ni_number,
    uk_vat_number,
]
