#!/usr/bin/env python3
"""Populate holiday_markers table with bank holidays, school holidays, Easter dates."""
from datetime import date, timedelta

# ── UK Bank Holidays (England & Wales) from gov.uk API ─────────
bank_holidays = [
    ("2021-01-01", "New Year's Day"),
    ("2021-04-02", "Good Friday"),
    ("2021-04-05", "Easter Monday"),
    ("2021-05-03", "Early May bank holiday"),
    ("2021-05-31", "Spring bank holiday"),
    ("2021-08-30", "Summer bank holiday"),
    ("2021-12-27", "Christmas Day (substitute)"),
    ("2021-12-28", "Boxing Day (substitute)"),
    ("2022-01-03", "New Year's Day (substitute)"),
    ("2022-04-15", "Good Friday"),
    ("2022-04-18", "Easter Monday"),
    ("2022-05-02", "Early May bank holiday"),
    ("2022-06-02", "Spring bank holiday"),
    ("2022-06-03", "Platinum Jubilee bank holiday"),
    ("2022-08-29", "Summer bank holiday"),
    ("2022-09-19", "State Funeral of Queen Elizabeth II"),
    ("2022-12-26", "Boxing Day"),
    ("2022-12-27", "Christmas Day (substitute)"),
    ("2023-01-02", "New Year's Day (substitute)"),
    ("2023-04-07", "Good Friday"),
    ("2023-04-10", "Easter Monday"),
    ("2023-05-01", "Early May bank holiday"),
    ("2023-05-08", "Coronation of King Charles III"),
    ("2023-05-29", "Spring bank holiday"),
    ("2023-08-28", "Summer bank holiday"),
    ("2023-12-25", "Christmas Day"),
    ("2023-12-26", "Boxing Day"),
    ("2024-01-01", "New Year's Day"),
    ("2024-03-29", "Good Friday"),
    ("2024-04-01", "Easter Monday"),
    ("2024-05-06", "Early May bank holiday"),
    ("2024-05-27", "Spring bank holiday"),
    ("2024-08-26", "Summer bank holiday"),
    ("2024-12-25", "Christmas Day"),
    ("2024-12-26", "Boxing Day"),
    ("2025-01-01", "New Year's Day"),
    ("2025-04-18", "Good Friday"),
    ("2025-04-21", "Easter Monday"),
    ("2025-05-05", "Early May bank holiday"),
    ("2025-05-26", "Spring bank holiday"),
    ("2025-08-25", "Summer bank holiday"),
    ("2025-12-25", "Christmas Day"),
    ("2025-12-26", "Boxing Day"),
    ("2026-01-01", "New Year's Day"),
    ("2026-04-03", "Good Friday"),
    ("2026-04-06", "Easter Monday"),
    ("2026-05-04", "Early May bank holiday"),
    ("2026-05-25", "Spring bank holiday"),
    ("2026-08-31", "Summer bank holiday"),
    ("2026-12-25", "Christmas Day"),
    ("2026-12-28", "Boxing Day (substitute)"),
]

# ── Cornwall School Holiday Ranges ─────────────────────────────
# Each entry: (start_date, end_date, name)
# These are the FULL breaks (not just half-term weeks)
school_holiday_ranges = [
    # 2021
    ("2021-03-29", "2021-04-16", "Easter 2021"),       # ~2 weeks around Easter
    ("2021-05-31", "2021-06-04", "Summer half term 2021"),
    ("2021-07-23", "2021-09-05", "Summer 2021"),
    ("2021-10-25", "2021-10-29", "Autumn half term 2021"),
    ("2021-12-18", "2022-01-03", "Christmas 2021"),
    # 2022
    ("2022-02-21", "2022-02-25", "Spring half term 2022"),
    ("2022-04-09", "2022-04-24", "Easter 2022"),
    ("2022-05-30", "2022-06-03", "Summer half term 2022"),
    ("2022-07-27", "2022-09-04", "Summer 2022"),
    ("2022-10-24", "2022-10-28", "Autumn half term 2022"),
    ("2022-12-17", "2023-01-02", "Christmas 2022"),
    # 2023
    ("2023-02-13", "2023-02-17", "Spring half term 2023"),
    ("2023-04-01", "2023-04-16", "Easter 2023"),
    ("2023-05-29", "2023-06-02", "Summer half term 2023"),
    ("2023-07-22", "2023-09-03", "Summer 2023"),
    ("2023-10-23", "2023-10-27", "Autumn half term 2023"),
    ("2023-12-20", "2024-01-03", "Christmas 2023"),
    # 2024
    ("2024-02-12", "2024-02-16", "Spring half term 2024"),
    ("2024-03-29", "2024-04-14", "Easter 2024"),
    ("2024-05-27", "2024-05-31", "Summer half term 2024"),
    ("2024-07-25", "2024-09-02", "Summer 2024"),
    ("2024-10-28", "2024-11-01", "Autumn half term 2024"),
    ("2024-12-21", "2025-01-05", "Christmas 2024"),
    # 2025
    ("2025-02-17", "2025-02-21", "Spring half term 2025"),
    ("2025-04-05", "2025-04-21", "Easter 2025"),
    ("2025-05-26", "2025-05-30", "Summer half term 2025"),
    ("2025-07-24", "2025-09-02", "Summer 2025"),
    ("2025-10-27", "2025-10-31", "Autumn half term 2025"),
    ("2025-12-20", "2026-01-04", "Christmas 2025"),
    # 2026
    ("2026-02-16", "2026-02-20", "Spring half term 2026"),
    ("2026-04-06", "2026-04-19", "Easter 2026"),
    ("2026-05-25", "2026-05-29", "Summer half term 2026"),
    ("2026-07-24", "2026-09-01", "Summer 2026"),
]

# ── Easter Dates for special tagging ───────────────────────────
easter_sundays = [
    "2021-04-04", "2022-04-17", "2023-04-09",
    "2024-03-31", "2025-04-20", "2026-04-05",
]

# ── Generate SQL ───────────────────────────────────────────────
sql = "INSERT INTO holiday_markers (event_date, event_type, event_name) VALUES\n"
rows = []

# Bank holidays
for dt_str, name in bank_holidays:
    rows.append(f"('{dt_str}', 'bank_holiday', '{name.replace(chr(39), chr(39)+chr(39))}')")

# Easter Sundays
for dt_str in easter_sundays:
    rows.append(f"('{dt_str}', 'easter', 'Easter Sunday')")

# School holiday ranges (expanded to individual dates)
for start_str, end_str, name in school_holiday_ranges:
    start = date.fromisoformat(start_str)
    end = date.fromisoformat(end_str)
    current = start
    while current <= end:
        rows.append(f"('{current.isoformat()}', 'school_holiday', '{name}')")
        current += timedelta(days=1)

# Write SQL
sql += ",\n".join(rows) + "\nON CONFLICT (event_date, event_type) DO NOTHING;"

print(f"-- Generated {len(rows)} holiday marker rows")
print(sql)
