# Customizing pg_collector + the modern viewer

This document is the end-to-end guide for **adding a new section** to
`pg_collector.sql` *and* making it look good in `tools/enhance.html`.

If you only want to tweak the viewer's appearance (themes, labels,
default state), see [`tools/README.md`](README.md). This file is for
the case where you're touching the SQL script too.

## The contract

The viewer parses the rendered HTML report by walking `<a name="X">`
anchors. Everything between two anchors is one section. So the
minimum you need to emit a new section that the viewer will pick up
and render is:

```sql
\qecho <a name="My_New_Section"></a>
\qecho <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#16191f"><b>My New Section</b></font><hr align="left" width="460">
\qecho <br>
SELECT … your data …;
\qecho <br>
```

That's it. The viewer will:

- pick up the anchor and put a `My_New_Section` entry in the sidebar
- restyle the `<table>` from your `SELECT` (zebra rows, padding, hover)
- auto-detect numeric columns and right-align them with tabular numerals
- make every column sortable on click (asc → desc → original order)
- add inline SVG size-bars to columns named `*size*`, `*bytes*`, or `*length*`
- hide the section automatically if the only output is "No X found" text

You get all of that for free. You only have to do extra work when you
want the section grouped with related ones, severity-flagged, or rendered
with a custom layout (like the DB Parameters page).

## Step 1 — Add the section to `pg_collector.sql`

Anchors and the styled header are emitted by `\qecho`. Pick a stable
anchor name (the convention is `Underscored_Title_Case`).

```sql
-- Inside the detail-sections region (~line 649 onwards in v3.2)
\qecho <a name="Sessions_By_App"></a>
\qecho <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#16191f"><b>Sessions by application_name</b></font><hr align="left" width="460">

\qecho <br>
\qecho <h3>Active sessions grouped by application_name :</h3>
SELECT application_name,
       count(*)               AS session_count,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle')   AS idle
FROM   pg_stat_activity
GROUP  BY application_name
ORDER  BY session_count DESC;
\qecho <br>
```

### Step 1b — Register it in the Navigation Table

Section won't be reachable from the report's TOC unless you add a TOC
entry around lines 105–205 in the script:

```html
<td nowrap align="center" width="25%"><a class="link" href="#Sessions_By_App">Sessions by app</a></td>
```

(Replace one of the `******` placeholder cells if you have a free slot.)

The viewer doesn't actually read the script's TOC — it builds its own
sidebar from anchors directly. But the original raw-HTML report does
need it for users opening that file directly.

### Step 1c — (optional) Add an Observations check

If the new section can flag a problem (e.g., "more than 50 idle
sessions"), add an entry to the Observations block. The pattern:

```sql
SELECT count(*) > 0 AS obsrv_too_many_idle
FROM   pg_stat_activity
WHERE  state = 'idle'
HAVING count(*) > 50 \gset

\if :obsrv_too_many_idle
\qecho '&#8594; The database has more than 50 idle sessions, please check the following section <a class="link" href="#Sessions_By_App">Sessions by app</a> .'
\qecho <br>
\else
\endif
```

`\gset` captures the boolean into a psql variable. `\if :varname`
gates the `\qecho`. **The `obsrv_*` variable name must yield `true` or
`false`, not `t`/`f`** — `count(*) > 0 as flagname` is the idiom.

### Step 1d — (optional) Version gating

If your query uses a catalog column or function introduced in a
specific PG major, gate it the same way the script gates
`pg_stat_statements` v1.9+:

```sql
SELECT current_setting('server_version_num')::int >= 140000 AS pg14_or_later \gset
\if :pg14_or_later
SELECT … query that needs PG14+ catalog …;
\else
\qecho This section requires PostgreSQL 14 or later.
\endif
```

A failed catalog reference aborts the rest of the statement and
leaves ugly error text in the report — gate, don't rely on graceful
degradation.

## Step 2 — Group it in the viewer's sidebar

The viewer's sidebar is grouped by category. New anchors fall into the
"Other" group automatically; to put yours into a named group, add it
to `SECTION_GROUPS` in `tools/enhance.html`:

```js
const SECTION_GROUPS = [
  // …existing groups…
  { label: 'Replication & sessions', sections: [
      'Replication', 'sessions_info', 'background_processes',
      'Sessions_By_App',  // ← new
  ]},
];
```

Section anchor names must match exactly. To find what your script
emits, view-source on the rendered report and search for `<a name=`.

## Step 3 — (optional) Severity-flag any new observation

If you added an Observations check (Step 1c), classify it in `RUBRIC`
so the finding is bubbled to the top. First match wins:

```js
const RUBRIC = [
  // …existing entries…
  { sev: 'warn', re: /more\s+than\s+50\s+idle\s+sessions/i,
    label: 'Too many idle sessions',
    why: 'Idle sessions consume backend slots and may indicate a connection-pool leak.' },
];
```

`sev` is one of `'crit'` / `'warn'` / `'note'`. `re` is matched
case-insensitively against the observation text. `label` and `why`
appear in the findings block and the rubric modal. Default for
unmatched observations is `'note'`.

## What you get for free (generic rendering)

For most sections, the section emits a `<table>` and the viewer's
generic rendering handles the rest. Specifically:

| Feature | Trigger |
|---|---|
| Sortable columns | Every `<table>` in section bodies. |
| Numeric column detection | ≥85% of non-blank cells parse as numeric (with optional unit). |
| Right-align + tabular numerals | Cells in detected numeric columns. |
| Size-bar viz | Column header matches `/\b(size\|bytes\|length)\b/`. |
| Empty-section pruning | Section text is empty, "This is not Aurora instance", or starts with "No X" and is < 120 chars. |
| Section badge in sidebar | Section is the link target of one or more observations. |

## When generic isn't enough — custom rendering

Some sections benefit from custom UI (the DB Parameters section is the
canonical example: 378 rows × 17 columns is unreadable as a flat
table, so it's redesigned with category groups, search, non-default
filter, and the inline pgtune panel).

The pattern is three pieces:

### 1. A typed parser in `parseReport()`

Augment `parseReport()` to extract structured data from your section,
attached to the section's record so it's also available via
`window.pgcReport`:

```js
function parseReport(html) {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  // …existing extraction…
  for (const s of sections) {
    if (s.anchor === 'DB_parameters') s.params = parseParamsTable(s);
    if (s.anchor === 'Sessions_By_App') s.sessionRows = parseSessionsByApp(s);  // ← new
  }
  return { title, dbInfo, observations, sections };
}

function parseSessionsByApp(section) {
  const wrap = document.createElement('div');
  wrap.innerHTML = section.html;
  const tbl = wrap.querySelector('table');
  if (!tbl) return [];
  const headers = [...tbl.querySelectorAll('th')].map(th => th.textContent.trim().toLowerCase());
  return [...tbl.querySelectorAll('tr')].slice(1).map(r => {
    const cells = [...r.querySelectorAll('td')].map(td => td.textContent.trim());
    const obj = {};
    headers.forEach((h, i) => { obj[h] = cells[i] || ''; });
    return obj;
  });
}
```

This is also the foundation for downstream tooling (CSV export,
SQLite import, cross-report diff): the structured data is in
`pgcReport.sections.find(s => s.anchor === 'Sessions_By_App').sessionRows`.

### 2. A decorator that renders the custom UI

```js
function decorateSessionsByApp(scope, rows) {
  // Hide or replace the original table; build cards / charts / whatever.
  // See decorateDbParams() in enhance.html for a complete example.
}
```

### 3. A hook in `renderSectionDetail()`

```js
function renderSectionDetail(s, issues) {
  // …existing…
  const body = det.querySelector('.section-body');
  if (s.anchor === 'DB_parameters' && Array.isArray(s.params) && s.params.length) {
    decorateDbParams(body, s.params);
  }
  if (s.anchor === 'Sessions_By_App' && Array.isArray(s.sessionRows)) {
    decorateSessionsByApp(body, s.sessionRows);                      // ← new
  }
  decorateTables(body);
  decorateSizeColumns(body);
  return det;
}
```

Always call `decorateTables(body)` *after* your custom decoration —
that way any `<table>` your decorator leaves visible still gets the
generic sort/numeric treatment.

## Worked example — adding "Sessions by app"

Pulling the pieces from the steps above into one diff:

**`pg_collector.sql`** (in the detail-sections region):

```sql
\qecho <a name="Sessions_By_App"></a>
\qecho <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#16191f"><b>Sessions by application_name</b></font><hr align="left" width="460">
\qecho <h3>Active sessions grouped by application_name:</h3>
SELECT application_name,
       count(*) AS session_count,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle')   AS idle
FROM   pg_stat_activity
GROUP  BY application_name
ORDER  BY session_count DESC;
\qecho <br>
```

**`pg_collector.sql`** (in the navigation table):

```html
<td nowrap align="center" width="25%"><a class="link" href="#Sessions_By_App">Sessions by app</a></td>
```

**`tools/enhance.html`** (`SECTION_GROUPS` config):

```js
{ label: 'Replication & sessions', sections: [
    'Replication', 'sessions_info', 'background_processes',
    'Sessions_By_App',
]},
```

That's it. Reload the viewer with a fresh report and you'll see:

- A new "Sessions by app" entry in the sidebar's "Replication & sessions" group.
- The section renders with sort-able columns; `session_count`, `active`, `idle` auto-detected as numeric and right-aligned.
- If the section is empty (no rows), it's hidden via empty-state pruning.

## Testing your change

1. **Run `pg_collector.sql` against any Postgres**:
   ```bash
   PGHOST=localhost PGUSER=postgres \
       ./tests/run.sh --isolate --seed populated --with-pgss --with-aurora-mock
   ```
2. **Open the enhanced view**:
   ```bash
   xdg-open tools/enhance.html
   # then drag the report from tests/artifacts/<ts>/report.html onto the page
   ```
3. **Verify**:
   - Anchor exists in source: `grep -c '<a name="Sessions_By_App"' tests/artifacts/<ts>/report.html`
   - Sidebar entry appears in the right group.
   - Table sorts on every column.
4. **Optional — add to CI**: extend `tests/fixtures/seed_health_checks.sql` to seed a condition that trips your new observation, then `tests/report_assertions.py`'s `OBSERVATION_MARKERS` dict gets a new entry and `tests/run.sh`'s `--expect-observations` list adds your short name. See [`tests/DESIGN.md`](../tests/DESIGN.md) §"Adding a new health check" for the exact recipe.

## Common pitfalls

- **Anchor with spaces**: `<a name="Some Section">` works in HTML but the URL-fragment becomes `#Some Section` (with a literal space). The viewer handles this, but `Some_Section` (underscore) is the project convention. Stay consistent.
- **Forgetting `<br>` after content**: section bodies sometimes run together without trailing whitespace. The viewer's parser is robust to this, but the raw report can look squished. Add `\qecho <br>` after each query block.
- **Apostrophes in `\qecho`**: psql's quoting is sensitive. Either avoid apostrophes in qecho text, or single-quote the whole line: `\qecho 'this isn''t great either'`. Match surrounding style.
- **Anchor naming collision**: two `<a name="X">` with the same name confuses both the original report's TOC and the viewer's sidebar. Pick unique anchors.
- **Forgetting version gating**: a query that references `pg_stat_io` will fail on PG15-and-older with an aborted-statement error spilling into the rendered report. Gate on `server_version_num`.

## Reference

- The viewer's `CONFIG` region (`RUBRIC`, `SECTION_GROUPS`, `LABELS`,
  `DEFAULTS`) is documented in [`tools/README.md`](README.md).
- Test-suite contract for adding fixtures and observations is in
  [`tests/DESIGN.md`](../tests/DESIGN.md).
- The script's architecture (preamble / nav / observations / details /
  Aurora / terminator) is in the project root [`CLAUDE.md`](../CLAUDE.md).
- The HTML5 parsing quirk that drives the viewer's Range-API extraction
  is documented inline in `tools/enhance.html` near `extractSections()`.
