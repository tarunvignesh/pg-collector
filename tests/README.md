# pg-collector tests

This directory contains the test harness for `pg_collector.sql`. Two layers:

1. **Static lint** (`tests/lint/*.py`) — runs in seconds, no database.
2. **Runtime tests** (`tests/run.sh` + fixtures) — spin up Postgres, seed, run
   the script as a read-only role, and assert the generated HTML report.

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

Runtime tests against a throwaway docker Postgres:

```bash
# Start a container bound to localhost:5432
docker run --rm -d --name pgc-test \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=pgc_test \
  -p 5432:5432 postgres:17

# Wait a beat for it to be ready, then run the tests.
./tests/run.sh --seed populated --with-pgss --with-aurora-mock

# Cleanup
docker rm -f pgc-test
```

`run.sh` flags:

| Flag | Effect |
|---|---|
| `--seed empty` | default; baseline fixture only. |
| `--seed populated` | also apply `seed_health_checks.sql`. |
| `--with-pgss` | install `pg_stat_statements`. |
| `--with-aurora-mock` | install `seed_aurora_mock.sql` so the Aurora branch executes. |
| `--as-role <name>` | run `pg_collector.sql` as `<name>` instead of `pgc_runner`. |
| `--skip-seed` | don't run any fixture (use existing DB state). |
| `--skip-diff` | don't take before/after schema snapshots. |

## BYO-DSN mode — run against your own database

You can point the same assertion harness at any Postgres you have
read-only access to. This mode does **not** seed, does **not** take
snapshots, and does **not** mutate anything in your database — it runs
`pg_collector.sql` and validates the produced report.

```bash
PGHOST=db.internal.example \
PGPORT=5432 \
PGUSER=readonly_user \
PGPASSWORD=*** \
PGDATABASE=app_prod \
  ./tests/run.sh --skip-seed --skip-diff --as-role readonly_user
```

Output: `tests/artifacts/<timestamp>/report.html` plus assertion results
on stdout. You get the same trust properties CI uses — no write attempts,
structurally valid report, anchor/section integrity — against your own
data.

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
