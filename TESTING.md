# Testing

This document catalogs every check the test suite performs and what each
one proves. For instructions on *running* the suite see
[tests/README.md](tests/README.md). For internal architecture decisions
(fixture design, role layout, the Aurora mock) see
[tests/DESIGN.md](tests/DESIGN.md).

## Summary

| Test ID | Layer | Needs DB | What it proves |
|---|---|---|---|
| `test_lint[check_safety.py]`        | Static  | No  | Every SQL statement in the script is read-only; no side-effecting function calls. |
| `test_lint[check_toc.py]`           | Static  | No  | Every nav-table `href="#X"` resolves to an `<a name="X">` anchor. |
| `test_lint[check_if_endif.py]`      | Static  | No  | Every `\if` is properly closed, including nested Aurora gates. |
| `test_lint[check_dialect.py]`       | Static  | No  | Every embedded SQL query parses as valid PostgreSQL. |
| `test_runtime[empty-seed]`          | Runtime | Yes | The script runs read-only end-to-end, mutates nothing, and produces a structurally valid HTML report. |
| `test_runtime[populated-pgss-aurora]` | Runtime | Yes | All CI-seedable observations fire correctly and the Aurora-specific branch executes. |

## Layer 1 — Static lint (no DB)

Each lint test runs the named Python checker as a subprocess against
`pg_collector.sql` and asserts exit zero. The checker source lives in
`tests/lint/`. Total runtime: under 1 second.

### `test_lint[check_safety.py]` — the trust check

Tokenizes `pg_collector.sql` (strips `\qecho` display strings, `--` and
`/* */` comments, single-quoted and dollar-quoted strings), splits on
unquoted `;` and mid-line `\gset`, and asserts every resulting statement
starts with a read-only keyword: `SELECT`, `WITH`, `VALUES`, `SHOW`,
`EXPLAIN`, `DEALLOCATE`. Also rejects any reference to side-effecting
server functions: `pg_terminate_backend`, `pg_stat_statements_reset`,
`pg_advisory_lock`, `pg_switch_wal`, etc. `PREPARE` statements are
allowed only when the prepared body is itself read-only; `EXECUTE` is
allowed only against a previously-defined safe `PREPARE`.

**Proves**: `pg_collector.sql` cannot mutate a production database.

### `test_lint[check_toc.py]` — link integrity

Greps the script for `href="#X"` references in the rendered navigation
tables and asserts each has a matching `<a name="X">` section anchor
inside the same script.

**Proves**: every link in the rendered report's TOC actually goes
somewhere. Catches the regression that broke `FK_without_index` in v2.8
and was fixed in v2.9.

### `test_lint[check_if_endif.py]` — control-flow balance

Tokenizes psql control flow (`\if`, `\elif`, `\else`, `\endif`) and
asserts proper balance, including nested gates. The Aurora
`\if :isaurora` blocks nest 2–3 deep inside version gates.

**Proves**: no hanging `\if` accidentally swallows a 500-line section,
and no extra `\endif` accidentally duplicates one.

### `test_lint[check_dialect.py]` — SQL syntax

Extracts each embedded SQL query from the script and parses it through
libpg_query (via the `pglast` Python binding). Replaces psql variable
substitutions (`:name`, `:'name'`, `:"name"`) with placeholders before
parsing, and skips one opaque `PREPARE` body whose runtime substitution
defeats static parsing.

**Proves**: every query is syntactically valid PostgreSQL — catches
dialect bugs (column renames, deprecated syntax) that only surface
against specific PG majors.

## Layer 2 — Runtime harness (requires PG)

Each runtime test runs `./tests/run.sh --isolate` with different
seeding flags. The runner's job is to: `createdb` a temp database,
apply fixtures, snapshot non-catalog relations, run
`pg_collector.sql` as the read-only `pgc_runner` role, snapshot
again, diff, then validate the produced HTML report. The pytest test
asserts `run.sh` exits zero and prints its `>>> PASS` banner.

### `test_runtime[empty-seed]`

Runs with `--isolate --seed empty`. Applies only the baseline fixture
(`tests/fixtures/seed_common.sql`) — creates the `pgc_admin` and
`pgc_runner` roles, the `pgc_fixture` schema with 50 accounts and 500
events.

**Proves four things**:

1. The script runs to completion as a role with only read privileges.
   `pgc_runner` is granted every read-class predefined role
   (`pg_read_all_data`, `pg_read_all_stats`, `pg_read_all_settings`,
   `pg_read_server_files`, `pg_monitor`), so the only thing left to
   deny is a write. Any `permission denied` during the run aborts the
   test.
2. The before-snapshot of `pg_class.relname + reltuples` for non-catalog
   relations is byte-identical to the after-snapshot. **The
   write-detection trust proof — belt-and-suspenders against the
   Layer 1 tokenizer.**
3. The rendered HTML report's `PG COLLECTOR V<X.Y>` header matches the
   script's `-- version : V X.Y` comment (catches script/report
   version drift).
4. Every `href="#X"` in the *rendered* report (not just the source
   script) resolves to an anchor, and 17 required core sections are
   present (Database_size, vacuum_Statistics, Replication, etc.).

### `test_runtime[populated-pgss-aurora]`

Same as `empty-seed` plus three additions:

- **`--seed populated`** applies `tests/fixtures/seed_health_checks.sql`,
  which deliberately trips 14 of the 19 v3.2 observation triggers:
  duplicate indexes, invalid indexes, near-wrap sequences, idle
  replication slots, tables with >20% dead rows, disabled
  `track_counts`, `enable_indexscan`, `enable_indexonlyscan`,
  `autovacuum`, `synchronous_commit`, excessive `log_statement`,
  table-level `autovacuum_enabled=false`, SSL-less connections,
  unused indexes.
- **`--with-pgss`** installs the `pg_stat_statements` extension so the
  script's `pg_stat_statements`-querying code paths execute instead of
  erroring benignly.
- **`--with-aurora-mock`** installs a view (`pgc_aurora_mock.pg_settings`)
  that shadows `pg_catalog.pg_settings` with a synthetic row
  `rds.extensions = 'aurora_stat_utils'`, plus stubs for
  `aurora_version()` and friends. This forces `\if :isaurora` to
  evaluate true so the Aurora-only branch executes against community
  Postgres.

**Additional proofs on top of `empty-seed`**:

5. Each of the 14 observation warning markers appears in the
   Observations block of the rendered report.
6. The report contains zero "This is not Aurora instance" banners — the
   Aurora mock successfully engaged the Aurora code path.

## What these tests do *not* cover

Four observations need real-world conditions that a minutes-long CI run
can't fabricate. The lint layer asserts the `\if` branch *exists* and
contains only read statements; runtime firing requires manual
validation on real production data.

| Observation | Why CI can't trigger it |
|---|---|
| Orphaned prepared transactions | Threshold is 5 minutes — too long for CI. |
| Transaction ID wraparound | Would require ~2³¹ transactions. |
| Logical replication spill files | Needs `wal_level=logical` plus a long-lived slot with pending decoded work. |
| Specific invalid-database conditions | Cannot be reliably fabricated. |

The CHANGELOG-listed `Outdated Extensions` check is also soft-asserted:
whether it fires depends on whether the host PG distribution ships a
newer version of `pg_trgm` than the one installed by the fixture. CI
treats it as best-effort.

## How the three layers compose

| Layer | Speed | Catches |
|---|---|---|
| Static lint | seconds, no DB | Mutating SQL keywords, broken TOC links, unbalanced `\if`, syntax errors. |
| Runtime read-only role | minutes, throwaway PG | Anything that bypasses the tokenizer (e.g. dynamic `EXECUTE`). Any `permission denied` is a write attempt. |
| Runtime schema diff | minutes, throwaway PG | Anything that slipped through the first two because the role had more privilege than expected. |

Each layer is weaker than the next on its own; together they form the
defensible "this script is safe to run on production" claim from the
README. All three must pass for a change to merge.

## PostgreSQL version coverage

The repo follows a branch-per-major model: `main` targets PG12 and
older; each `pg_major: 13+` has its own branch. Each branch carries
the version-specific catalog/syntax workarounds.

This branch's CI matrix runs the runtime harness against **PG12 through
PG18** (7 majors × pgss on/off × seed empty/populated × aurora
none/mocked = 56 cells). That's intentionally broader than this
branch's strict PG12-and-older target — failures on PG13+ here are
early-warning signals for the per-major branches, not strict
merge-blockers on `main`.

| Branch | Strict target | What CI tests on PR |
|---|---|---|
| `main` | PG12 and older | PG12-PG18 (this matrix) |
| `pg13`, `pg14`, … (separate) | The named major | Each branch maintains its own scoped matrix |

The single-version pytest **`report` job** (the one rendered in the PR
Checks UI) runs against PG17 — a deliberately conservative
"representative stable" rather than the bleeding edge. The matrix
catches version-specific regressions; the report surfaces test-suite
results.

When PG19 GA's, the maintainer should:
1. Append `19` to the matrix `pg_major:` list.
2. Decide whether to drop the oldest EOL'd major (currently PG12).
3. Update this section to reflect the change.

## Generating a report

Local:

```bash
PGHOST=localhost PGUSER=postgres \
    pytest tests/test_harness.py \
    --html=tests/artifacts/test-report/test_report.html \
    --self-contained-html \
    --junitxml=tests/artifacts/test-report/junit.xml
```

The HTML report includes a Description column (one or two sentences per
test) sourced from `tests/conftest.py`. Open
`tests/artifacts/test-report/test_report.html` directly in a browser.

CI uploads the same files as a workflow artifact; the JUnit XML drives
the per-PR test summary in the Actions UI.
