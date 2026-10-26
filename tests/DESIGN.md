# pg-collector test suite — design notes

This is the internal "how and why" companion to `tests/README.md`. README tells
you how to run the suite; this document explains what each test proves, how
the fixture architecture came together, and the traps encountered while
building it.

## What we're proving

The PG Collector README promises the script is "safe to run on production
environments and does not create any database objects." The test suite has
to make that claim *mechanically defensible*. The tests are organized into
three layers, each weaker than the next on its own but strong in combination:

| Layer | Speed | Proves |
|---|---|---|
| Static lint | seconds, no DB | The checked-in SQL has no write statements, no side-effecting function calls, no unbalanced `\if`, no broken TOC links, no syntax errors. |
| Runtime read-only-role | minutes, throwaway PG | The whole script, through every conditional branch that the seeded DB exercises, runs to completion under a role that cannot write. Any attempt to write fails with `permission denied`. |
| Runtime schema diff | minutes, throwaway PG | Even given a role that *could* write, before/after snapshots of non-catalog tables are identical. Belt-and-suspenders against privilege-escalation paths. |

Layer 1 catches regressions *at PR time* without needing a Postgres. Layer 2
catches attempts to write that would bypass layer 1 (e.g. via a dynamic
`EXECUTE` that the tokenizer couldn't prove safe). Layer 3 catches anything
that slipped through the first two because the role had more privilege than
we expected. All three must pass for a change to merge.

## Test inventory

### Static checks (`tests/lint/*.py`)

- `check_safety.py` — the core trust check. A hand-written tokenizer strips
  `\qecho` lines, `--`/`/* */` comments, and quoted strings, then splits on
  unquoted `;` (and `\gset`-style mid-line terminators). For each resulting
  statement, the first keyword must be a read-class keyword (SELECT, WITH,
  VALUES, SHOW, EXPLAIN, DEALLOCATE, EXECUTE of a known-safe PREPARE).
  The check also fails on any reference to a side-effecting function
  (`pg_terminate_backend`, `pg_stat_statements_reset`, `pg_advisory_lock`,
  `pg_switch_wal`, etc.).

- `check_toc.py` — ensures every `href="#X"` in the rendered navigation
  tables has a matching `<a name="X">` section anchor. This catches the
  exact regression fixed in v2.9 ("Fix link issue (FK_without_index)").

- `check_if_endif.py` — `\if`/`\elif`/`\else`/`\endif` balance, including
  nested blocks (the Aurora gates nest 2–3 deep). Unbalanced blocks
  silently swallow or duplicate large ranges of the report, so this is
  worth a dedicated check.

- `check_dialect.py` — each embedded query is parsed by libpg_query (via
  `pglast`). Psql variable substitutions (`:name`, `:'name'`, `:"name"`)
  are replaced with placeholders before parsing. Catches syntax bugs that
  only show up against specific PG majors.

- `check_div_by_zero.py` — every division's divisor is classified, and a
  live statistics counter in a denominator fails the build unless it is
  guarded. A parse check cannot catch this: `rows / calls` is valid SQL
  that aborts a section the moment `calls` is 0. Written after upstream
  issue #10, where a concurrent `pg_stat_statements_reset()` blanked
  several sections of a customer's report.

### Runtime harness (`tests/run.sh`)

`run.sh` composes fixtures, executes the script, and runs HTML assertions.
Its contract:

1. Seed the database **as a superuser** with the roles, schema, and health-
   check triggers described below. Seeding can be skipped (`--skip-seed`).
2. Snapshot non-catalog schema + row counts **before** invoking the script.
3. Invoke `pg_collector.sql` **as `pgc_runner`** (or `--as-role <name>`),
   which has only read privileges.
4. Snapshot **after**; diff must be empty.
5. Pass the generated HTML to `report_assertions.py`.

### HTML assertions (`tests/report_assertions.py`)

Invariants asserted on the rendered report:

- Version string `PG COLLECTOR V<X.Y>` matches the `-- version : V X.Y`
  comment in the script header. Prevents script/report version drift.
- Every `href="#X"` resolves to an `<a name="X">` (re-run of the lint check
  against the *rendered* HTML, catches emit-time mistakes).
- A `REQUIRED_SECTIONS` list of ~17 core anchors is present.
- Observation warnings fire iff their triggers were seeded (or don't fire
  in empty-DB mode).
- Aurora sections render real content when `aurora=mocked`, and the
  "This is not Aurora instance" banner when `aurora=none`.

## Fixtures — architecture and gotchas

### Role structure

```
postgres (superuser)        — CI container default; runs the fixtures.
  │
  ├── pgc_admin             — owns pgc_fixture schema objects. Not used by
  │                           the test runner directly; exists so fixture
  │                           DDL has a clean, non-superuser owner.
  │
  └── pgc_runner            — the role that runs pg_collector.sql.
                              Granted: pg_read_all_data, pg_read_all_stats,
                                       pg_read_all_settings, pg_read_server_files,
                                       pg_monitor, plus explicit EXECUTE on
                                       pg_hba_file_rules() and pg_config().
                              NOT granted: any write privilege anywhere.
```

The runner role accumulates every **read** privilege PG offers. That's
deliberate: with all read privs, a `permission denied` error during script
execution can *only* come from a write attempt. This turns the runtime test
into a mechanical write-detector — no allowlisting of "benign" permission
errors is needed.

Gotcha: `pg_hba_file_rules()` and `pg_config()` are read-only introspection
functions whose EXECUTE privilege defaults to superuser in recent PG
majors. They're not covered by any predefined read role, so they need
explicit `GRANT EXECUTE`. This is handled inside `DO ... EXCEPTION WHEN
OTHERS` so the fixture still works on PG majors where the signature
differs or the function doesn't exist.

### Seeded schema

Three tables: `accounts` (50 rows), `events` (500 rows, FK to accounts,
two indexes), and `dead_rows`/`autovac_off` (added by the health-check
fixture). Sized so pg_stat_user_tables shows meaningful numbers and so
`dead_rows` can cross the `(n_live_tup > 1000 OR n_dead_tup > 1000)`
threshold that v3.2's dead-rows observation checks.

### The Aurora mock

PG Collector detects Aurora via:

```sql
SELECT count(*) > 0 AS isaurora
FROM pg_settings
WHERE name = 'rds.extensions' AND setting LIKE '%aurora_stat_utils%';
```

Naively: `ALTER SYSTEM SET rds.extensions = 'aurora_stat_utils'` plus
`SELECT pg_reload_conf()`. **This does not work on PG18** (and likely
earlier majors). Custom GUCs with an unreserved prefix don't show up in
`pg_catalog.pg_settings` unless a loadable C extension registers them via
`DefineCustomStringVariable`. `ALTER SYSTEM`, `SET`, `ALTER DATABASE ...
SET`, even adding the line to `postgresql.conf` and restarting — none of
them cause the GUC to appear in the `pg_settings` view.

The workaround: **shadow `pg_settings` itself**. The Aurora mock fixture
creates a view `pgc_aurora_mock.pg_settings` that UNION-ALLs the real
`pg_catalog.pg_settings` with a synthetic row for `rds.extensions`, then
sets `search_path = pgc_aurora_mock, pg_catalog, public` at the database
level. Unqualified `pg_settings` references in `pg_collector.sql` resolve
to the mock view first. The Aurora `aurora_*()` function stubs live in
the same schema and resolve the same way.

This is a deliberate, very narrow kind of lie: PG Collector *thinks* it's
running on Aurora, and its `\if :isaurora` branch executes. The stubs
return empty result sets, so we don't assert on the content of Aurora
sections — just on the fact that the branch runs without crashing psql.
Real Aurora behavior requires AWS.

### Ordering trap: track_counts vs dead_rows

Observation #10 (track_counts disabled) and observation #14 (tables with
>20% dead rows) **interact**: disabling `track_counts` freezes the
statistics collector, and any DELETE after that point doesn't update
`n_dead_tup` in `pg_stat_all_tables`. Naive fixture ordering (alphabetic
or numeric by check) disables track_counts before the DELETE, so #14
never fires.

Fix: the fixture disables `track_counts` **last** — after the
`INSERT`/`DELETE` that seeds dead tuples, after a `pg_reload_conf()` that
applies the other settings, and after a `pg_sleep(1)` that lets the stats
subsystem flush counters. The existing statistics persist when
track_counts flips off; only new updates stop being tracked.

## Observations coverage matrix

| # | Observation | Seeded in CI? | Notes |
|---|---|---|---|
| 1 | Duplicate indexes | ✓ | Two identical `CREATE INDEX`. |
| 2 | Invalid indexes | ✓ | `UPDATE pg_index SET indisvalid = false` (superuser-only, fixture phase). |
| 3 | Unused indexes | ✓ | Any index with zero scans pre-first-query fires it. |
| 4 | autovacuum disabled | ✓ | `ALTER SYSTEM`. |
| 5 | Sequences <10% remaining | ✓ | `setval` on a low-MAXVALUE sequence. |
| 6 | Orphaned prepared txn | ✗ | Requires `interval '5 minute'` threshold; not CI-feasible. Presence of `\if` branch is lint-asserted. |
| 7 | SSL-less connections | ✓ | Default in CI PG container. |
| 8 | enable_indexonlyscan off | ✓ | `ALTER SYSTEM`. |
| 9 | Excessive logging | ✓ | `ALTER SYSTEM SET log_statement = 'all'`. |
| 10 | track_counts off | ✓ | `ALTER SYSTEM`, ordered last (see above). |
| 11 | enable_indexscan off | ✓ | `ALTER SYSTEM`. |
| 12 | synchronous_commit off | ✓ | `ALTER SYSTEM`. |
| 13 | Invalid databases | ✗ | Not reliably fabricable. Presence-only. |
| 14 | Tables >20% dead rows | ✓ | 2500 inserts, 1000 deletes, autovacuum disabled per-table. |
| 15 | TXID wraparound | ✗ | Would require 2³¹ txns. Presence-only. |
| 16 | Per-table autovacuum off | ✓ | `ALTER TABLE ... SET (autovacuum_enabled = false)`. |
| 17 | Inactive replication slots | ✓ | `pg_create_physical_replication_slot` (no wal_level=logical required). |
| 18 | Logical replication spill | ✗ | Needs wal_level=logical + multi-minute setup. Presence-only. |
| 19 | Outdated extensions | ~ | Best-effort `CREATE EXTENSION pg_trgm`. Whether it fires depends on whether the PG distribution ships a newer version than the one installed. Soft-assert. |

Coverage: **14/19 triggered, 4/19 presence-only, 1/19 soft**. The four
presence-only checks are asserted by `check_if_endif.py` (the branch
exists) and `check_safety.py` (the branch contains only reads); their
dynamic behavior requires manual validation on real production data.

## CI flow

`.github/workflows/lint.yml` — runs on every PR/push, <1 min, no DB.

`.github/workflows/test.yml` — matrix of `pg_major × pgss × seed × aurora`
= 48 cells. Each cell:

1. Starts a Postgres `services:` container at the matrix's major version.
2. Checks out the repo.
3. Installs `psql` and Python deps.
4. Calls `./tests/run.sh` with flags derived from the matrix cell.
5. Uploads `tests/artifacts/<timestamp>/` (report HTML, snapshots, logs)
   as a workflow artifact regardless of success.

On scheduled runs (weekly), the same matrix exercises the latest minor
releases of each major — early warning for upstream catalog changes.

## Adding a new health check

When PG Collector's Observations section adds check #20 in, say, v3.3:

1. **Script**: add the `\gset`/`\if`/`\qecho` stanza in the Observations
   block and the detail section it links to. Existing patterns at
   `pg_collector.sql:207-640` are the template.
2. **Fixture**: add a stanza to `tests/fixtures/seed_health_checks.sql`
   that trips the new check. If it can't be CI-triggered, add a comment
   explaining why and leave the fixture as-is.
3. **Assertion**: add an entry to `OBSERVATION_MARKERS` in
   `tests/report_assertions.py` mapping a short name to a substring
   that appears in the rendered warning.
4. **Runner**: if the new check is CI-reachable, append its short name to
   the `--expect-observations` list in `tests/run.sh`.
5. **This doc**: add a row to the Observations coverage matrix above.
6. **Bump the version string** in `pg_collector.sql` header, `<h1>`, and
   `CHANGELOG.md` — the report-assertions `check_version` test will fail
   loudly if you forget one.

## Adding a new static check

Drop `tests/lint/check_<name>.py` — one argument (path to SQL), stdout
on success, non-zero exit on failure. Add a step to
`.github/workflows/lint.yml`. The existing checks all follow this
convention.

## Debugging a failing assertion

Each run writes to `tests/artifacts/<timestamp>/`:

- `report.html` — the rendered report the assertions ran against.
- `psql_stdout.log` — what `psql -f pg_collector.sql` printed.
- `psql_stderr.log` — errors. Any `permission denied` here that isn't
  about `pg_stat_statements` (benign if the extension isn't installed)
  is a real regression.
- `snapshot_before.txt` / `snapshot_after.txt` / `snapshot_diff.txt` —
  schema + row-count state. A non-empty diff indicates a write.

For CI runs, these are uploaded as workflow artifacts named
`report-pg<major>-pgss<on|off>-<seed>-aurora<mode>`.

## Known limitations

- **Aurora content correctness**: the mock proves the branch runs, not
  that it produces Aurora-accurate output. Real coverage requires AWS.
- **4 observations need real-world duration** (prepared-txn age, TXID
  wraparound, logical replication spill, specific invalid-DB conditions).
  Manual validation only.
- **`pg_trgm` soft-assert**: some PG distributions don't ship the contrib
  package or ship only one version. When that happens, the outdated-
  extensions observation won't fire in CI. That's fine — we don't treat
  it as required.
- **PG versioning policy**: this branch targets PG19 per the project's
  branch-per-major policy, so the matrix runs PG17, PG18 and PG19beta3 —
  the target plus the two majors below it, which are what exercise the
  `extversion` gates guarding PG15-18-only catalog columns. All three are
  merge-blockers here; `main` (PG12-and-older) keeps its own wider,
  advisory matrix.
