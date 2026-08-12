#!/usr/bin/env python3
"""Fingerprint, suppress, deduplicate and rank the findings from a review run.

The reviewers emit findings; this script decides which of them survive to the report. It
exists because all four steps are exact work — a sha256 is either right or it is not — and a
model asked to produce one produces something that looks like one. A fingerprint that is
almost right silently breaks both features built on top of it: a suppressed false positive
comes back next week, and two specialists reporting the same defect print it twice.

Reads a findings payload on stdin, writes the merged payload on stdout:

    cat raw.json | python3 .claude/skills/rascal-review/scripts/merge_findings.py \\
        --suppressions .claude/review-history/false-positives.json > merged.json

Input is either ``{"findings": [...]}`` or a bare list. Each finding needs at least
``agent``, ``file``, ``rule``, ``code``, ``severity`` and ``confidence``; everything else is
carried through untouched.

Run it a second time after validation with the verdict confidences written back in — it is
idempotent, because a fingerprint is a pure function of rule, file and normalised code.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from typing import Any

# Severity order for ranking. Anything unrecognised sorts last rather than crashing the run;
# a reviewer inventing a severity is a skill bug worth seeing in the report, not a traceback.
SEVERITY_RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}

WHITESPACE = re.compile(r"\s+")


def normalize_code(code: str) -> str:
    """Collapse whitespace so reformatting does not mint a new fingerprint."""
    return WHITESPACE.sub(" ", (code or "").strip())


def fingerprint(finding: dict[str, Any]) -> str:
    """Stable identity for a finding: rule + file + the code it points at.

    Deliberately no line number. Line numbers move on every rebase and every insertion
    above, so a line-keyed fingerprint would expire a suppression the moment anyone edited
    the top of the file — which is exactly when you least want a known false positive back.
    The cost is that the same rule firing on two byte-identical lines in one file collapses
    to a single finding, which is the right answer nearly every time it happens.
    """
    payload = "|".join(
        [
            str(finding.get("rule", "")).strip(),
            str(finding.get("file", "")).strip(),
            normalize_code(str(finding.get("code", ""))),
        ]
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]


def active_suppressions(path: str | None, today: dt.date) -> set[str]:
    """Fingerprints of known false positives that have not expired."""
    if not path:
        return set()
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return set()
    except json.JSONDecodeError as exc:
        # A malformed suppression file must not silently disable suppression — that would
        # flood the next review with findings someone already ruled out.
        raise SystemExit(f"{path} is not valid JSON: {exc}") from exc

    entries = data.get("entries", []) if isinstance(data, dict) else data
    active = set()
    for entry in entries:
        expires = entry.get("expires_at")
        if expires:
            try:
                if dt.date.fromisoformat(str(expires)[:10]) <= today:
                    continue
            except ValueError:
                # An unparseable date is treated as expired: suppression is the permissive
                # direction, so an unreadable rule should stop suppressing, not keep going.
                continue
        if entry.get("fingerprint"):
            active.add(str(entry["fingerprint"]))
    return active


def severity_of(finding: dict[str, Any]) -> str:
    return str(finding.get("severity", "")).upper()


def merge_pair(kept: dict[str, Any], other: dict[str, Any]) -> dict[str, Any]:
    """Fold a duplicate into the record already held.

    Two specialists reaching the same defect is corroboration, so the merged record keeps
    the higher confidence and the more severe classification, and records both names.
    """
    sources = list(dict.fromkeys(kept.get("sources", []) + other.get("sources", [])))
    kept["sources"] = sources
    kept["confidence"] = max(int(kept.get("confidence", 0)), int(other.get("confidence", 0)))
    if SEVERITY_RANK.get(severity_of(other), 99) < SEVERITY_RANK.get(severity_of(kept), 99):
        kept["severity"] = severity_of(other)
    # Keep the earliest line the defect was reported at, so the report points at the top of
    # a multi-line problem rather than wherever the second reviewer happened to look.
    for key in ("line_start", "line_end"):
        values = [v for v in (kept.get(key), other.get(key)) if isinstance(v, int)]
        if values:
            kept[key] = min(values) if key == "line_start" else max(values)
    return kept


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suppressions", help="path to false-positives.json")
    parser.add_argument(
        "--min-confidence",
        type=int,
        default=80,
        help="drop findings below this confidence (default: 80)",
    )
    parser.add_argument(
        "--today",
        help="ISO date used to expire suppressions (default: today, UTC)",
    )
    args = parser.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        raise SystemExit("no findings on stdin")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"stdin is not valid JSON: {exc}") from exc

    findings = payload.get("findings", []) if isinstance(payload, dict) else payload
    if not isinstance(findings, list):
        raise SystemExit("expected a list of findings")

    # `dt.timezone.utc` rather than `dt.UTC`: this runs under whatever `python3` is on PATH,
    # which on a Mac with Xcode installed is 3.9, not the 3.12 in api/.venv.
    today = (
        dt.date.fromisoformat(args.today) if args.today else dt.datetime.now(dt.timezone.utc).date()
    )
    suppressed_fingerprints = active_suppressions(args.suppressions, today)

    merged: dict[str, dict[str, Any]] = {}
    suppressed: list[dict[str, Any]] = []
    low_confidence: list[dict[str, Any]] = []
    duplicates = 0

    for finding in findings:
        if not isinstance(finding, dict):
            continue
        record = dict(finding)
        record["fingerprint"] = fingerprint(record)
        record["code"] = normalize_code(str(record.get("code", "")))
        record["severity"] = severity_of(record)
        record.setdefault("sources", [record.get("agent")] if record.get("agent") else [])

        if record["fingerprint"] in suppressed_fingerprints:
            suppressed.append(record)
            continue
        if int(record.get("confidence", 0)) < args.min_confidence:
            low_confidence.append(record)
            continue

        existing = merged.get(record["fingerprint"])
        if existing is None:
            merged[record["fingerprint"]] = record
        else:
            duplicates += 1
            merged[record["fingerprint"]] = merge_pair(existing, record)

    ranked = sorted(
        merged.values(),
        key=lambda f: (
            SEVERITY_RANK.get(severity_of(f), 99),
            -int(f.get("confidence", 0)),
            str(f.get("file", "")),
            int(f.get("line_start", 0) or 0),
        ),
    )

    json.dump(
        {
            "findings": ranked,
            "findings_count": len(ranked),
            "suppressed": suppressed,
            "suppressed_count": len(suppressed),
            "duplicate_count": duplicates,
            "dropped_low_confidence": [
                {
                    "fingerprint": f["fingerprint"],
                    "file": f.get("file"),
                    "confidence": f.get("confidence"),
                    "description": f.get("description"),
                }
                for f in low_confidence
            ],
            "dropped_low_confidence_count": len(low_confidence),
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
