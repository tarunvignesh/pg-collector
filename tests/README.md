# pg-collector tests

This directory contains the test harness for `pg_collector.sql`. Two layers:

1. **Static lint** (`tests/lint/*.py`) — runs in seconds, no database.
2. **Runtime tests** (`tests/run.sh` + fixtures) — spin up Postgres, seed, run
   the script as a read-only role, and assert the generated HTML report.

Companion docs:
- [`../TESTING.md`](../TESTING.md) — what each test proves, with descriptions.
- [`DESIGN.md`](DESIGN.md) — fixture architecture, the Aurora mock, gotchas.

## What the harness proves

- **Safety**: `check_safety.py` tokenizes the script and fails on any write
  keyword at statement position, plus any call to a side-effecting function
  (`pg_terminate_backend`, `pg_stat_statements_reset`, etc.).
- **Read-only at runtime**: `run.sh` executes the script as a role with
  only `pg_read_all_data` (PG14+) or explicit SELECT grants (PG12/13). If
  the script ever attempts a write, psql emits `permission denied` and the
  run fails.
- **Structural integrity**: every `href="#X"` in the rendered report
  resolves to an `<a name="X">`; every `\if` has a matching `\endif`;
  every embedded query parses under libpg_query.
- **Observations wiring**: the seeded-DB mode triggers each v3.2 health
  check that can be fabricated in a minutes-long window, then asserts the
  corresponding warning appears in the report.

## Running locally

Dependencies (one-time):

```bash
pip install pglast beautifulsoup4
```

Static lint, no DB needed:

```bash
python tests/lint/check_safety.py    pg_collector.sql
python tests/lint/check_toc.py       pg_collector.sql
python tests/lint/check_if_endif.py  pg_collector.sql
python tests/lint/check_dialect.py   pg_collector.sql
```

### Runtime tests — BYOD (bring your own database)

Locally, point `run.sh` at any Postgres you have. The recommended
invocation creates a temporary database inside your cluster, runs the
full harness (seed + diff + assertions) against that temp DB, and drops
it on exit. No docker dependency, no risk to your existing databases.

```bash
PGHOST=localhost PGUSER=postgres \
    ./tests/run.sh --isolate --seed populated --with-pgss --with-aurora-mock
```

Caveats:
- Your role needs the `CREATEDB` privilege.
- `seed_common.sql` creates cluster-wide roles `pgc_admin` and
  `pgc_runner`. They persist after the temp DB is dropped (idempotent —
  subsequent runs don't re-create). To remove them, see "Fixture
  teardown" below.

#### Variant: read-only against a real database

To validate the rendered report against a staging or production read
replica without seeding or mutating anything, drop `--isolate` and add
`--skip-seed --skip-diff`. Only structural assertions apply (version
string, anchor parity, required sections).

```bash
PGHOST=db.internal.example PGUSER=readonly_user PGPASSWORD=*** \
PGDATABASE=app_prod \
    ./tests/run.sh --skip-seed --skip-diff --as-role readonly_user
```

Output for both flows: `tests/artifacts/<timestamp>/report.html` plus
assertion results on stdout.

### Running with a structured test report

For a unified pass/fail/duration report (the same format CI publishes
on PRs), use the pytest wrapper. Each test row includes a Description
column explaining what was checked — see [../TESTING.md](../TESTING.md)
for the catalog.

```bash
pip install -r tests/requirements.txt
PGHOST=localhost PGUSER=postgres pytest tests/test_harness.py \
    --html=tests/artifacts/test-report/test_report.html \
    --self-contained-html \
    --junitxml=tests/artifacts/test-report/junit.xml
```

Open `tests/artifacts/test-report/test_report.html` in a browser.

### CI

GitHub Actions runs two jobs on every PR:
- **`pytest report (pg17)`** — invokes the pytest wrapper above against
  PG17, publishes JUnit results to the PR Checks UI via
  `EnricoMi/publish-unit-test-result-action`, and uploads the
  self-contained HTML report as a workflow artifact named `test-report`.
- **`matrix-test`** — the cross-version compatibility sweep (PG12–17 ×
  pgss on/off × seed empty/populated × aurora none/mocked = 48 cells)
  using `run.sh` directly. Each cell uploads its own pg_collector
  output as an artifact.

No local setup required for either — push a PR and both run.

### `run.sh` flags

| Flag | Effect |
|---|---|
| `--seed empty` | default; baseline fixture only. |
| `--seed populated` | also apply `seed_health_checks.sql`. |
| `--with-pgss` | install `pg_stat_statements`. |
| `--with-aurora-mock` | install `seed_aurora_mock.sql` so the Aurora branch executes. |
| `--as-role <name>` | run `pg_collector.sql` as `<name>` instead of `pgc_runner`. |
| `--skip-seed` | don't run any fixture (use existing DB state). |
| `--skip-diff` | don't take before/after schema snapshots. |
| `--isolate` | createdb a temp database, run inside it, drop on exit. |

## Fixtures

| File | Purpose |
|---|---|
| `fixtures/seed_common.sql` | Baseline schema (`pgc_fixture` namespace), two roles (`pgc_admin` owner, `pgc_runner` read-only), ~500 rows. |
| `fixtures/seed_health_checks.sql` | Duplicate indexes, invalid indexes, near-wrap sequence, idle replication slot, dead rows, disabled planner/logging/autovacuum params — trips as many v3.2 Observations as are CI-reachable. |
| `fixtures/seed_aurora_mock.sql` | Sets `rds.extensions = aurora_stat_utils`, stubs `aurora_version()`, `aurora_replica_status()`, `aurora_ccm_status()`, etc. Makes the script's `\if :isaurora` branch execute against community Postgres. Not a faithful simulator — just enough to prove the branch runs. |

## Observations that the CI harness *cannot* trigger

Three health checks need real-world conditions that a minutes-long CI run
can't fabricate. The static lint asserts their `\if` branches exist; runtime
coverage must come from manual validation on real databases:

- **Orphaned prepared transactions** — threshold is 5 minutes.
- **TXID wraparound** — needs ~2³¹ transactions.
- **Logical replication spill files** — needs `wal_level=logical` plus a
  long-lived logical slot with pending decoded work.

## Fixture teardown

`run.sh` does not drop its fixture objects — subsequent runs against the
same database reuse the baseline (`CREATE IF NOT EXISTS` everywhere). If
you want a clean slate:

```sql
DROP SCHEMA IF EXISTS pgc_fixture CASCADE;
DROP SCHEMA IF EXISTS pgc_aurora_mock CASCADE;
DROP ROLE IF EXISTS pgc_runner;
DROP ROLE IF EXISTS pgc_admin;
ALTER SYSTEM RESET ALL;
SELECT pg_reload_conf();
```
