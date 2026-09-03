# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`pg_collector.sql` is a **single-file psql script** (~7200 lines on this branch) that queries a running PostgreSQL database and emits an HTML diagnostic report to `<outdir>/pg_collector_<dbname>-<timestamp>.html` (`outdir` defaults to `/tmp`; override with `-v outdir=/path`). It is read-only apart from one `SET statement_timeout` on its own session: it creates no tables, functions, or extensions. There is no build step and no package manager. Tests and CI live in `tests/` and `.github/workflows/` — see [TESTING.md](TESTING.md).

## Running the script

```bash
# Against a local/remote Postgres (requires psql client only):
psql -h <host> -p <port> -d <dbname> -U <user> -f pg_collector.sql

# Or interactively inside psql:
\i pg_collector.sql
```

Output is announced on the last two lines (`Report Generated Successfully` + path). The script ends with `\q`, so interactive sessions will exit after it runs.

Two classes of errors are **expected and benign** (documented in README):
- `relation "pg_stat_statements[_info]" does not exist` when that extension is not installed (partially mitigated as of v3.1 by a pre-check, but some call sites may still raise).
- `Cluster Cache Manager is disabled` on Aurora when CCM is off.

To abort slow queries on a huge catalog: `SET statement_timeout = 30000;` before `\i`.

## Versioning / branch policy

Each PostgreSQL major version (PG13+) gets its own branch; `main` targets PG12 and older. **This branch tracks `pg-collector-for-postgresql-19`**, whose script is a different product from `main`'s V3.2 — roughly 7200 lines vs 4000, 74 sections vs 56.

The version string appears twice: the script header (line 6) and the rendered report's `<h1>` (line 399). Both must stay in sync with `CHANGELOG.md` when bumping.

Two features from the upstream 2026-06 release change how the script is invoked, and both matter when writing tests:

- **Selective section execution** — `-v fullmod=f -v vacuum=t -v bloat=t` renders only the named sections; `-v help=t` lists the section variables. Nearly every section is wrapped in `\if :do_<section>`, so control flow is much denser than on `main`.
- **Configurable output** — `-v outdir=/path`.

## Architecture of the SQL script

Reading the whole file linearly is rarely what you want. The big-picture structure is:

1. **Preamble (lines 1–398)** — selective-execution variable parsing and the `-v help=t` block, `SET statement_timeout = '5min'`, psql output config (`\pset format html`, CSS in `\qecho`), filename derivation (`\set filename :DBNAME-\`date ...\``), server-type detection, and the `DB INFO` header. Server type (`Aurora-*`, `RDS-*`, `pg-*`) and DB role (Primary vs Standby) are computed here via `\gset` and emitted into the report.
2. **Navigation tables (~lines 399–920)** — the partial-report banner (emitted when `fullmod=f`) followed by two HTML tables of `<a href="#anchor">` links. The first is core sections; the second is Amazon Aurora-specific sections. **Every new section must add a TOC entry here and an `<a name="…"></a>` anchor at the section itself**, otherwise it won't be reachable from the report.
3. **Observations section (~lines 921–1370)** — automated health check. Each check follows the same pattern:
   ```
   select count(*) > 0 obsrv_<name> from <diagnostic query> \gset
   \if :obsrv_<name>
       \qecho '&#8594; <warning text with <a href="#anchor">link to detail section</a>>'
   \else
   \endif
   ```
   New checks plug into this block and should cross-link to the detail section that already renders the raw data.
4. **Detail sections (~lines 1371–5320)** — one section per topic (Database size, Transaction ID, Extensions, Vacuum, Memory, pg_stat_statements, Replication, Sessions, Fragmentation, Duplicate indexes, plus Foreign Servers, Materialized Views, Index Creation Progress and Temp Tables & Files added in the 2026-06 release). Each begins with `\qecho <a name="X"></a>` and a styled `<h1>`/`<h2>` header, then runs SELECTs wrapped in `\qecho <details>…</details>` tags (collapsible since v2.9).
5. **Aurora and Aurora Limitless sections (~lines 5321–7170)** — gated behind `\gset isaurora` / `\if :isaurora` and `\if :isauroralimitless`. **These gates have no `\else` arm on this branch**: on community PG the sections and their TOC entries are omitted entirely, where `main` printed a "This is not Aurora instance" placeholder. Assertions that key on that placeholder string are wrong here.
6. **Terminator (lines ~7166–7173)** — resets format, closes output, prints the "Report Generated Successfully" banner. This must stay last.

### Recurring idioms to preserve

- **`\gset` + `\if`** is the only control flow available. Any "run this only when X" must be expressed as a boolean-returning SELECT captured via `\gset`, then gated with `\if :varname`. Nested `\if` inside `\if` is used in Aurora/version gates — mind the `\endif` pairing.
- **Version gates** (e.g., `v_pgstatextv19` around line 1533) parse `extversion` via `regexp_split_to_array` to decide whether a view/column exists. When adding queries that reference catalog objects introduced in a specific PG or extension version, gate them the same way — do not rely on the server rejecting a missing relation gracefully, because it aborts the current transaction/statement and leaves ugly errors in the report.
- **Boolean variables from `\gset`** must be `true`/`false` (not `t`/`f`) for `\if` to evaluate them — the script uses `count(*) > 0 as flagname` idiomatically.
- **No semicolons after `\gset`-terminated statements** — the `\gset` replaces the semicolon.
- **All HTML goes through `\qecho`**, which emits literal text. Apostrophes inside `\qecho` strings need care; the existing code sometimes single-quotes whole lines (`\qecho 'text'`) and sometimes not — follow the surrounding style.

## Adding a health check (Observations section)

For an end-to-end walkthrough that also covers making the new section
render well in `tools/enhance.html` (the modern post-processor viewer),
see [`tools/CUSTOMIZING.md`](tools/CUSTOMIZING.md).

`CHANGELOG.md` lists the existing checks. To add one:
1. Pick an anchor name that matches the detail section the check should link to.
2. In the Observations block, add a `select count(*) > 0 obsrv_<name> ... \gset` + `\if :obsrv_<name>` stanza with a `\qecho` containing a `<a class="link" href="#<anchor>">` link.
3. If the detail section doesn't exist yet, add it below (with `<a name="...">` anchor) and register it in the Navigation table.
4. Update `README.md`'s health-check list and `CHANGELOG.md`.

## Testing this project

The suite is in `tests/`, documented in [TESTING.md](TESTING.md) (what each check
proves), `tests/README.md` (how to run it) and `tests/DESIGN.md` (why it is built
this way). Two layers:

- **Static lint**, no database — `tests/lint/check_{safety,toc,if_endif,dialect}.py`.
  `check_dialect.py` needs `pglast`; the rest are stdlib-only.
- **Runtime**, needs a database — `tests/run.sh` seeds `tests/fixtures/`, runs the
  script, and applies `tests/report_assertions.py` to the generated HTML.

`.github/workflows/test.yml` runs both: a `report` job publishing a pytest HTML
artifact, and a `matrix-test` job over PG 17 / 18 / 19beta3 × pgss × seed × aurora.
`.github/workflows/lint.yml` runs the static layer alone.

Invariants worth preserving:

- Always `psql -v ON_ERROR_STOP=0` — the script legitimately raises the benign
  errors documented in README, so `ON_ERROR_STOP=1` would fail a healthy run.
- The pass condition is `Report Generated Successfully` on stdout **plus** the
  HTML assertions; stdout alone will not catch a section that silently produced
  no rows.
- `tests/fixtures/seed_aurora_mock.sql` shadows `pg_settings` and stubs the
  `aurora_*` functions so the Aurora branch executes on community PG. When
  upstream adds an Aurora section, the mock needs a matching stub or the run
  fills with `function ... does not exist` noise.

## Files to know

- `pg_collector.sql` — the entire product.
- `sample_reports/pg_collector_testdb-2020-10-16_021546.html` — reference output (older v2.x format) useful for diffing.
- `CHANGELOG.md` — authoritative per-version feature list; keep in sync when bumping the `V X.Y` string in the script header and `<h1>`.
- `README.md` — user-facing run instructions and health-check list. When adding a check or section, update both here and in the script.
