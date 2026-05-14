#!/usr/bin/env python3
"""
validate-services.py — schema-validate /home_ai/config/payments/services.yaml.

Runs before n8n picks the file up (or as a CI step). Exits 0 on success, 1 on
the first validation error. Prints all errors so a single run catches the
whole batch.

Per AGENTS.md rule: no secrets in the file. Only Vault paths.

Usage:
    python3 scripts/payments/validate-services.py
    python3 scripts/payments/validate-services.py --file /path/to/services.yaml
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("ERROR: pyyaml not installed. Inside a container: docker exec ... pip install pyyaml")

DEFAULT_PATH = Path("/home_ai/config/payments/services.yaml")
VALID_REALMS = {"owner", "work", "family", "shared"}
VALID_ADAPTERS = {"api", "scrape", "csv"}
VALID_SIGN_CONVENTIONS = {"negative_is_outflow", "amount_plus_type_flag"}
SECRET_NEEDLES = (
    "password", "secret", "api_key", "private_key", "bot_token",
    "client_secret", "session_token",
)
VAULT_PATH_RE = re.compile(r"^secret/[a-z0-9_-]+(/[a-z0-9_-]+)+$")
CRON_RE = re.compile(r"^[\d*/,-]+\s+[\d*/,-]+\s+[\d*/,-]+\s+[\d*/,-]+\s+[\d*/,-]+$")


class Errors:
    def __init__(self) -> None:
        self.entries: list[str] = []

    def add(self, where: str, msg: str) -> None:
        self.entries.append(f"  [{where}] {msg}")

    def __len__(self) -> int:
        return len(self.entries)


def _no_secret_values(node, path: str, errs: Errors) -> None:
    """Walk the parsed YAML and reject literal-looking secrets."""
    if isinstance(node, dict):
        for k, v in node.items():
            kl = str(k).lower()
            if any(needle in kl for needle in SECRET_NEEDLES) and isinstance(v, str):
                if not VAULT_PATH_RE.match(v):
                    errs.add(f"{path}.{k}",
                             f"looks like a secret literal — should be a Vault path. Got: {v[:30]!r}")
            _no_secret_values(v, f"{path}.{k}", errs)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _no_secret_values(v, f"{path}[{i}]", errs)


def _validate_cron(value, where: str, errs: Errors) -> None:
    if value is None or value == "watch":
        return
    if not isinstance(value, str) or not CRON_RE.match(value):
        errs.add(where, f"not a 5-field cron expression: {value!r}")


def _validate_source(name: str, src: dict, errs: Errors) -> None:
    base = f"sources.{name}"

    realm = src.get("realm")
    if realm not in VALID_REALMS:
        errs.add(f"{base}.realm", f"must be one of {sorted(VALID_REALMS)}, got {realm!r}")

    primary = src.get("primary_adapter")
    if primary not in VALID_ADAPTERS:
        errs.add(f"{base}.primary_adapter", f"must be one of {sorted(VALID_ADAPTERS)}, got {primary!r}")

    chain = src.get("fallback_chain", [])
    if not isinstance(chain, list):
        errs.add(f"{base}.fallback_chain", "must be a list (may be empty)")
    else:
        for i, a in enumerate(chain):
            if a not in VALID_ADAPTERS:
                errs.add(f"{base}.fallback_chain[{i}]", f"invalid adapter {a!r}")

    fm = src.get("freshness_minutes")
    if not isinstance(fm, int) or fm <= 0:
        errs.add(f"{base}.freshness_minutes", "must be a positive integer")

    schedule = src.get("schedule") or {}
    if not isinstance(schedule, dict):
        errs.add(f"{base}.schedule", "must be a mapping of adapter → cron")
    else:
        for adapter, cron in schedule.items():
            if adapter not in VALID_ADAPTERS:
                errs.add(f"{base}.schedule.{adapter}", f"unknown adapter {adapter!r}")
            _validate_cron(cron, f"{base}.schedule.{adapter}", errs)

    vault = src.get("vault") or {}
    if not isinstance(vault, dict):
        errs.add(f"{base}.vault", "must be a mapping of name → vault path")
    else:
        for k, v in vault.items():
            if not isinstance(v, str) or not VAULT_PATH_RE.match(v):
                errs.add(f"{base}.vault.{k}",
                         f"not a valid Vault path (expected `secret/x/y[/...]`), got {v!r}")

    csv_fmt = src.get("csv_format") or {}
    if not isinstance(csv_fmt, dict):
        errs.add(f"{base}.csv_format", "must be a mapping")
    else:
        idc = csv_fmt.get("identifier_columns")
        if not isinstance(idc, list) or len(idc) == 0:
            errs.add(f"{base}.csv_format.identifier_columns", "must be a non-empty list of column names")
        sc = csv_fmt.get("sign_convention")
        if sc not in VALID_SIGN_CONVENTIONS:
            errs.add(f"{base}.csv_format.sign_convention",
                     f"must be one of {sorted(VALID_SIGN_CONVENTIONS)}, got {sc!r}")

    if primary == "csv" and "csv" in chain:
        errs.add(f"{base}.fallback_chain", "primary is already csv — don't list csv again in fallback")


def validate(path: Path) -> int:
    errs = Errors()
    if not path.exists():
        sys.stderr.write(f"ERROR: file not found at {path}\n")
        return 2

    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        sys.stderr.write(f"ERROR: YAML parse failure: {e}\n")
        return 2

    if doc.get("schema_version") != 1:
        errs.add("schema_version", f"must be 1, got {doc.get('schema_version')!r}")

    sources = doc.get("sources") or {}
    if not isinstance(sources, dict) or not sources:
        errs.add("sources", "must be a non-empty mapping of <name> → source-config")
    else:
        for name, src in sources.items():
            if not isinstance(src, dict):
                errs.add(f"sources.{name}", "must be a mapping")
                continue
            _validate_source(name, src, errs)

    _no_secret_values(doc, "root", errs)

    if errs.entries:
        print(f"FAIL — {len(errs)} validation error(s) in {path}:", file=sys.stderr)
        for e in errs.entries:
            print(e, file=sys.stderr)
        return 1

    print(f"OK — {path} valid, {len(sources)} source(s) configured.")
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--file", type=Path, default=DEFAULT_PATH)
    args = p.parse_args()
    sys.exit(validate(args.file))
