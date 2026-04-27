"""pytest-html customization: per-test Description column.

Adds a column to the rendered HTML test report that explains, in plain
English, what each test actually checks. Without this column the report
shows test IDs like `test_lint[check_safety.py]` which require the reader
to know the codebase.

The descriptions are stored as a flat dict keyed by the trailing
`name[parametrize-id]` segment of the pytest nodeid.
"""

from __future__ import annotations

import html

import pytest

DESCRIPTIONS: dict[str, str] = {
    "test_lint[check_safety.py]": (
        "Tokenizes pg_collector.sql (stripping \\qecho lines, comments, "
        "quoted strings) and asserts every SQL statement starts with a "
        "read-only keyword (SELECT, WITH, VALUES, SHOW, EXPLAIN). Also "
        "fails on calls to side-effecting functions like "
        "pg_terminate_backend, pg_stat_statements_reset, pg_advisory_lock, "
        "or pg_switch_wal. This is the core trust proof that the script "
        "cannot mutate a production database."
    ),
    "test_lint[check_toc.py]": (
        "Asserts every href=\"#X\" link in the report's navigation "
        "tables resolves to a matching <a name=\"X\"> section anchor. "
        "Catches the exact regression fixed in v2.9 (broken "
        "FK_without_index link)."
    ),
    "test_lint[check_if_endif.py]": (
        "Counts \\if / \\elif / \\else / \\endif tokens and verifies "
        "balance, including nested blocks (Aurora gates nest 2-3 deep). "
        "Unbalanced blocks silently swallow or duplicate large ranges of "
        "the rendered report."
    ),
    "test_lint[check_dialect.py]": (
        "Parses each embedded SQL query through libpg_query (via pglast) "
        "to validate PostgreSQL syntax. Psql variable substitutions like "
        ":name and :'name' are replaced with placeholders before parsing. "
        "Catches dialect bugs that only surface against specific PG majors."
    ),
    "test_runtime[empty-seed]": (
        "Boots a temporary database, applies the baseline fixture (roles "
        "+ 50 accounts + 500 events), runs pg_collector.sql as the "
        "read-only pgc_runner role, and asserts: exit zero, the report's "
        "version + anchors + required sections are valid, and a "
        "before/after snapshot of non-catalog relations is byte-identical "
        "(write-detection)."
    ),
    "test_runtime[populated-pgss-aurora]": (
        "Same as empty-seed plus the full health-check fixture (duplicate "
        "indexes, invalid indexes, dead rows, disabled autovacuum, "
        "etc. — 14 trigger conditions), pg_stat_statements installed, "
        "and the Aurora mock engaged. Asserts each expected observation "
        "warning rendered in the report and the Aurora-only branch "
        "executed (no 'This is not Aurora instance' banner)."
    ),
}


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    last = item.nodeid.split("::")[-1]
    report.description = DESCRIPTIONS.get(last, "")


def pytest_html_results_table_header(cells):
    cells.insert(2, "<th>Description</th>")


def pytest_html_results_table_row(report, cells):
    desc = getattr(report, "description", "") or ""
    cells.insert(2, f"<td>{html.escape(desc)}</td>")
