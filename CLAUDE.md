# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`pg_collector.sql` is a **single-file psql script** (~4000 lines) that queries a running PostgreSQL database and emits an HTML diagnostic report to `/tmp/pg_collector_<dbname>-<timestamp>.html`. It is read-only: it creates no tables, functions, or extensions. There is no build step, no package manager, and (at time of writing) no automated tests or CI workflows.

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

Each PostgreSQL major version (PG13+) gets its own branch. The `main` branch targets PG12 and older. The currently-checked-out `main` is tagged v3.2 in the script header (line 6) and in the rendered report's `<h1>` (line 63). Those two strings must be kept in sync when bumping versions, along with `CHANGELOG.md`.

## Architecture of the SQL script

Reading the whole file linearly is rarely what you want. The big-picture structure is:

1. **Preamble (lines 1–104)** — psql output config (`\pset format html`, CSS in `\qecho`), filename derivation (`\set filename :DBNAME-\`date ...\``), server-type detection, and the `DB INFO` header. Server type (`Aurora-*`, `RDS-*`, `pg-*`) and DB role (Primary vs Standby) are computed here via `\gset` and emitted into the report.
2. **Navigation tables (~lines 105–205)** — two HTML tables of `<a href="#anchor">` links. The first is core sections; the second is Amazon Aurora-specific sections. **Every new section must add a TOC entry here and an `<a name="…"></a>` anchor at the section itself**, otherwise it won't be reachable from the report.
3. **Observations section (~lines 207–640)** — automated health check. Each check follows the same pattern:
   ```
   select count(*) > 0 obsrv_<name> from <diagnostic query> \gset
   \if :obsrv_<name>
       \qecho '&#8594; <warning text with <a href="#anchor">link to detail section</a>>'
   \else
   \endif
   ```
   New checks plug into this block and should cross-link to the detail section that already renders the raw data.
4. **Detail sections (~lines 649–3600)** — one section per topic (Database size, Transaction ID, Extensions, Vacuum, Memory, pg_stat_statements, Replication, Sessions, Fragmentation, Duplicate indexes, etc.). Each begins with `\qecho <a name="X"></a>` and a styled `<h1>`/`<h2>` header, then runs SELECTs wrapped in `\qecho <details>…</details>` tags (collapsible since v2.9).
5. **Aurora-specific sections (~lines 3600–4000)** — gated behind `\gset isaurora` / `\if :isaurora` so they render as "This is not Aurora instance" on community PG.
6. **Terminator (lines 4004–4009)** — resets format, closes output, prints the "Report Generated Successfully" banner. This must stay last.

### Recurring idioms to preserve

- **`\gset` + `\if`** is the only control flow available. Any "run this only when X" must be expressed as a boolean-returning SELECT captured via `\gset`, then gated with `\if :varname`. Nested `\if` inside `\if` is used in Aurora/version gates — mind the `\endif` pairing.
- **Version gates** (e.g., `v_pgstatextv19` around line 1533) parse `extversion` via `regexp_split_to_array` to decide whether a view/column exists. When adding queries that reference catalog objects introduced in a specific PG or extension version, gate them the same way — do not rely on the server rejecting a missing relation gracefully, because it aborts the current transaction/statement and leaves ugly errors in the report.
- **Boolean variables from `\gset`** must be `true`/`false` (not `t`/`f`) for `\if` to evaluate them — the script uses `count(*) > 0 as flagname` idiomatically.
- **No semicolons after `\gset`-terminated statements** — the `\gset` replaces the semicolon.
- **All HTML goes through `\qecho`**, which emits literal text. Apostrophes inside `\qecho` strings need care; the existing code sometimes single-quotes whole lines (`\qecho 'text'`) and sometimes not — follow the surrounding style.

## Adding a health check (Observations section)

The CHANGELOG for v3.2 lists the 19 existing checks. To add one:
1. Pick an anchor name that matches the detail section the check should link to.
2. In the Observations block, add a `select count(*) > 0 obsrv_<name> ... \gset` + `\if :obsrv_<name>` stanza with a `\qecho` containing a `<a class="link" href="#<anchor>">` link.
3. If the detail section doesn't exist yet, add it below (with `<a name="...">` anchor) and register it in the Navigation table.
4. Update `README.md`'s health-check list and `CHANGELOG.md`.

## Testing this project (currently none; contribution target)

There is no existing test harness, fixture data, or GitHub Actions workflow. A contribution that adds CI should:

- Spin up Postgres service containers at multiple majors (matrix over PG12/13/14/15/16/17) via `services:` or `docker run`. The `main` branch targets PG12-and-older, but running against newer majors catches regressions in catalog-query compatibility and is worthwhile in CI.
- Seed a minimal schema (tables, an index or two, a role, optionally `CREATE EXTENSION pg_stat_statements` in a separate job to exercise both code paths).
- Invoke `psql -v ON_ERROR_STOP=0 -f pg_collector.sql` and **assert the final stdout contains `Report Generated Successfully`**. Do not use `ON_ERROR_STOP=1` — the script legitimately raises the benign errors documented in README.
- Validate the produced `/tmp/pg_collector_*.html` with an HTML parser (e.g., `tidy -e` or a small Python script) and assert each TOC anchor (`#Database_size`, `#Transaction_ID_TXID`, …) resolves to a matching `<a name="...">`. This catches the exact class of regression fixed in v2.9 ("Fix link issue FK_without_index").
- Optionally diff the section list against a golden list to catch accidental section deletions.

Place the workflow at `.github/workflows/ci.yml`. There is no pre-existing lint config to match.

## Files to know

- `pg_collector.sql` — the entire product.
- `sample_reports/pg_collector_testdb-2020-10-16_021546.html` — reference output (older v2.x format) useful for diffing.
- `CHANGELOG.md` — authoritative per-version feature list; keep in sync when bumping the `V X.Y` string in the script header and `<h1>`.
- `README.md` — user-facing run instructions and health-check list. When adding a check or section, update both here and in the script.
