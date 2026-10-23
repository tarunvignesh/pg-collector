#!/usr/bin/env python3
"""Structural assertions for a PG Collector HTML report.

Usage:
    python report_assertions.py --report <path> [options]

Checks (always):
  - Version string `PG COLLECTOR V<X.Y>` matches the script header.
  - Every `href="#X"` link in the report resolves to an `<a name="X">`.
  - A minimum set of core sections are present and non-empty.

Checks (conditional):
  --expect-observations <names>
      Comma-separated list of observation warnings that must be present.
      Example: --expect-observations duplicate_indexes,invalid_indexes
  --no-observations
      Assert no observation warnings fired (empty-DB mode).
  --aurora mocked | none
      `mocked`: Aurora sections must render data (no "not Aurora" banner).
      `none`:   Aurora sections must render the "not Aurora" banner.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup

# Core sections we expect to always render on any Postgres instance.
REQUIRED_SECTIONS = [
    "Database_size",
    "DB_parameters",
    "Transaction_ID_TXID",
    "Table_Size",
    "index_Size",
    "vacuum_Statistics",
    "Extensions",
    "Memory_setting",
    "Users_Roles_Info",
    "Schema_Info",
    "Tablespaces_Info",
    "Fragmentation",
    "Replication",
    "sessions_info",
    "ssl",
    "background_processes",
    "pg_config",
    "Materialized_Views",
    "Collation_Index_Risk",
    "Partitioning_Candidates",
]

# Observation-warning signature → substring (case-insensitive) we expect to
# see in the rendered Observations paragraph when the corresponding health
# check fires. Mapped back to the v3.2 CHANGELOG list.
OBSERVATION_MARKERS: dict[str, str] = {
    "duplicate_indexes":            "duplicate indexes",
    "invalid_indexes":              "invalid indexes",
    "unused_indexes":               "unused indexes",
    "autovacuum_parameter":         "autovacuum parameter is disabled",
    "sequences":                    "sequence",          # "sequences near their max value"
    "orphaned_prepared_txn":        "orphaned prepared",
    "ssl":                          "without ssl",
    "enable_indexonlyscan":         "enable_indexonlyscan",
    "excessive_logging":            "log_statement",
    "track_counts":                 "track_counts",
    "enable_indexscan":             "enable_indexscan",
    "synchronous_commit":           "synchronous_commit",
    "invalid_databases":            "invalid database",
    "dead_rows":                    "dead rows",
    "txid_wraparound":              "wraparound",
    "table_autovacuum_off":         "autovacuum_enabled",
    "inactive_replication_slots":   "inactive replication",
    "logical_replication_spill":    "spill",
    "outdated_extensions":          "upgrade available",
    "collation_mismatch":           "collation version mismatch",
    "matview_health":               "materialized views that are unpopulated",
    "partitioning_candidates":      "large tables that are not partitioned",
}

HREF_RE = re.compile(r'href="#([^"]+)"')
NAME_RE = re.compile(r'<a\s+name="([^"]+)"\s*>')
VERSION_HEADER_RE = re.compile(r"PG COLLECTOR\s*V\s*([\d.]+)", re.IGNORECASE)
SCRIPT_VERSION_RE = re.compile(
    r"^--\s*\|\s*--\s*version\s*:\s*V\s*([\d.]+)",
    re.IGNORECASE | re.MULTILINE,
)


def fail(msg: str, errors: list[str]) -> None:
    errors.append(msg)


def check_version(report_text: str, script_path: Path, errors: list[str]) -> None:
    m = VERSION_HEADER_RE.search(report_text)
    if not m:
        fail("report has no 'PG COLLECTOR V<X.Y>' header", errors)
        return
    rendered_v = m.group(1).strip()
    script_text = script_path.read_text(encoding="utf-8")
    sm = SCRIPT_VERSION_RE.search(script_text)
    if not sm:
        fail(f"cannot find version in script header ({script_path})", errors)
        return
    script_v = sm.group(1).strip()
    if rendered_v != script_v:
        fail(
            f"version mismatch: report says V{rendered_v}, script header says V{script_v}",
            errors,
        )


def check_anchor_parity(report_text: str, errors: list[str]) -> None:
    hrefs = {h for h in HREF_RE.findall(report_text)}
    anchors = {a for a in NAME_RE.findall(report_text)}
    meaningful = {h for h in hrefs if h != "top" and not re.match(r"^\*+$", h)}
    broken = sorted(meaningful - anchors)
    if broken:
        fail(f"report has {len(broken)} broken href(s): {broken[:8]}", errors)


def check_required_sections(report_text: str, errors: list[str]) -> None:
    anchors = set(NAME_RE.findall(report_text))
    missing = [s for s in REQUIRED_SECTIONS if s not in anchors]
    if missing:
        fail(f"required section(s) missing: {missing}", errors)


def observations_text(soup: BeautifulSoup) -> str:
    """Return the concatenated text of the Observations block — from the
    'Observations' header to the first `<a name="...">` section anchor that
    follows."""
    # find header
    header = None
    for f in soup.find_all("font"):
        if f.get_text(strip=True).lower().startswith("observations"):
            header = f
            break
    if header is None:
        return ""
    # walk forward siblings until next <a name="...">
    collected: list[str] = []
    for sib in header.next_elements:
        if getattr(sib, "name", None) == "a" and sib.get("name"):
            break
        if isinstance(sib, str):
            collected.append(sib)
    return " ".join(collected)


def check_observations(
    report_text: str,
    expect: list[str] | None,
    none: bool,
    errors: list[str],
) -> None:
    soup = BeautifulSoup(report_text, "html.parser")
    obs = observations_text(soup).lower()
    if none:
        fired = [
            name for name, marker in OBSERVATION_MARKERS.items()
            if marker.lower() in obs
        ]
        if fired:
            fail(
                f"empty-DB mode: unexpected observations fired: {fired}",
                errors,
            )
        return
    if expect:
        missing = []
        for name in expect:
            marker = OBSERVATION_MARKERS.get(name)
            if marker is None:
                fail(f"unknown observation name in --expect: {name}", errors)
                continue
            if marker.lower() not in obs:
                missing.append(name)
        if missing:
            fail(f"seeded observations did not fire: {missing}", errors)


def check_aurora(report_text: str, mode: str, errors: list[str]) -> None:
    """Assert the Aurora gate resolved the way the environment demands.

    Two upstream renderings of a non-Aurora run exist and both are correct:

    * `main` (PG12) wraps each Aurora block in `\\if :isaurora ... \\else`
      and prints a 'This is not Aurora instance' placeholder.
    * The PG19-era branches dropped the `\\else` arms, so the sections and
      their TOC entries are omitted from the report entirely.

    Keying on the placeholder string alone therefore fails on PG19 for a
    report that is perfectly correct. What actually matters in both is
    whether Aurora *content* rendered, so that is what we assert.
    """
    banner_hits = report_text.lower().count("this is not aurora instance")
    anchors = {a.lower() for a in NAME_RE.findall(report_text)}
    aurora_anchors = sorted(a for a in anchors if "aurora" in a or "limitless" in a)

    if mode == "mocked":
        if banner_hits > 0:
            fail(
                f"aurora=mocked: found 'This is not Aurora instance' "
                f"{banner_hits}x — stubs did not engage",
                errors,
            )
        if not aurora_anchors:
            fail(
                "aurora=mocked: no Aurora section anchors rendered — "
                "stubs did not engage",
                errors,
            )
    elif mode == "none":
        # Placeholder banners (main) and omitted sections (PG19) both pass;
        # Aurora sections that actually rendered do not.
        if aurora_anchors and banner_hits == 0:
            fail(
                f"aurora=none: Aurora sections rendered on a non-Aurora "
                f"server: {aurora_anchors[:5]}",
                errors,
            )


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--report", required=True, type=Path)
    p.add_argument("--script", default=Path("pg_collector.sql"), type=Path)
    p.add_argument(
        "--expect-observations",
        default="",
        help="comma-separated names; see OBSERVATION_MARKERS",
    )
    p.add_argument("--no-observations", action="store_true")
    p.add_argument("--aurora", choices=["mocked", "none"])
    args = p.parse_args(argv[1:])

    if not args.report.exists():
        print(f"report not found: {args.report}", file=sys.stderr)
        return 2

    text = args.report.read_text(encoding="utf-8", errors="replace")
    errors: list[str] = []

    check_version(text, args.script, errors)
    check_anchor_parity(text, errors)
    check_required_sections(text, errors)

    if args.no_observations and args.expect_observations:
        print(
            "cannot pass both --no-observations and --expect-observations",
            file=sys.stderr,
        )
        return 2

    expect = (
        [s.strip() for s in args.expect_observations.split(",") if s.strip()]
        if args.expect_observations
        else None
    )
    check_observations(text, expect, args.no_observations, errors)

    if args.aurora:
        check_aurora(text, args.aurora, errors)

    if errors:
        for e in errors:
            print(f"FAIL: {e}")
        print(f"\n{len(errors)} assertion(s) failed ({args.report})", file=sys.stderr)
        return 1

    print(f"all assertions passed ({args.report})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
