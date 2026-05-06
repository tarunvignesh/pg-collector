# tools/

Static utilities that wrap or post-process pg_collector output.
None of these modify `pg_collector.sql`.

## `enhance.html` — modern viewer

A self-contained, browser-only post-processor. Drop a `pg_collector_*.html`
report onto it (or pass `?report=URL`) and it renders a modern UI on top
of the existing report DOM:

- Hero stats (critical / warning / notice counts) above the fold
- Severity-grouped findings with rationale tooltips
- Sticky sidebar with section grouping, search, and scroll-spy
- Restyled tables, dark/light/auto theme, in-browser only (no upload)

### Open it

```bash
# direct file
xdg-open tools/enhance.html             # then drag-drop a report

# or serve and auto-load a specific report
python3 -m http.server 8770
# → http://127.0.0.1:8770/tools/enhance.html?report=/path/to/report.html
```

### Customizing it

The file is laid out so common tweaks happen in a single `CONFIG` region
of the `<script>` block. Each customization point is documented inline
with a comment block. The file's top comment header lists every entry
point — open `tools/enhance.html` and search for the matching section.

#### Recipe: change colors / theme

Every color is a CSS custom property in the `<style>` block under the
"DESIGN TOKENS" comment. To shift the entire palette, edit the values
in `:root`, `[data-theme=light]`, and `[data-theme=dark]`. Each block
defines the same set of tokens — keep them parallel.

To add a third theme (say `[data-theme=high-contrast]`):

1. In `<style>`, copy the entire `[data-theme=light]` block and rename:
   ```css
   [data-theme=high-contrast] {
       color-scheme: light;
       --bg: #ffffff;
       --text: #000000;
       --accent: #cc0000;
       /* …keep every token, override what you want… */
   }
   ```
2. In the sidebar markup, add a button to `.theme-toggle`:
   ```html
   <button data-theme-set="high-contrast">HC</button>
   ```

That's it — the existing `wireTheme()` handler picks up `data-theme-set`
automatically.

#### Recipe: add or change a severity rule

Edit `RUBRIC` at the top of `<script>`. First match wins. To add:

```js
const RUBRIC = [
  // …existing entries…
  { sev: 'crit', re: /your\s+pattern/i,
    label: 'Short label shown in findings',
    why: 'One-line rationale shown as tooltip and in the rubric modal.' },
];
```

To downgrade an existing rule, change its `sev` from `'crit'` to `'warn'`
or `'note'`. To remove a rule, delete the entry.

The rubric modal (linked in the sidebar as "Why these severities?") is
auto-built from this array — no extra wiring needed.

#### Recipe: regroup the sidebar

Edit `SECTION_GROUPS`. Each entry has a `label` and a list of section
anchor names (the `<a name="X">` values from `pg_collector.sql`). To
move a section into a different group, move its anchor name. Sections
not listed in any group fall through to the "Other" group automatically.

```js
const SECTION_GROUPS = [
  { label: 'Critical-path checks', sections: [
      'ssl', 'invalid_indexes', 'vacuum_Statistics',
  ]},
  // …
];
```

To return to a flat (un-grouped) sidebar list, set
`const SECTION_GROUPS = [];`.

#### Recipe: change wording (titles, footer, button copy)

Edit `LABELS`. Every user-facing string is in this object:

```js
const LABELS = {
  appName: 'Your custom name',
  heroCritical: 'Must fix',          // was 'Critical'
  heroWarnings: 'Worth a look',      // was 'Warnings'
  // …
  footer: 'Custom footer HTML…',
};
```

For internationalization, swap the entire `LABELS` object based on a
locale check (the renderer reads `LABELS.*` lazily — change anytime
before `applyLabels()` runs).

#### Recipe: change the initial UI state

Edit `DEFAULTS`:

```js
const DEFAULTS = {
  expandedBlocks: ['crit', 'warn'],   // which severity blocks open by default
  hideEmptySections: true,            // suppress "No X found" sections
  initialTheme: 'auto',               // 'auto' | 'light' | 'dark' | <custom>
};
```

#### Recipe: change the layout

Layout is CSS grid in `<style>`. Look for the `.app` rule:

```css
.app { display: grid; grid-template-columns: 280px minmax(0,1fr); … }
```

To widen the sidebar: change `280px`. To move the sidebar to the right:
swap the column order in markup or use `grid-template-areas`. To force
single-column always: `.app { grid-template-columns: 1fr; }`.

The responsive breakpoint that hides the sidebar on narrow viewports is
right below — adjust `max-width: 900px` to taste.

### File anatomy (where to look)

```
<style>
  DESIGN TOKENS         ← colors, sizes, shadows
  BASE TYPOGRAPHY
  DROP ZONE
  APP SHELL             ← layout grid
  SIDEBAR
  MAIN content
  HERO / SEV BLOCKS
  DB OVERVIEW
  SECTION RESTYLE       ← restyled psql tables
  RUBRIC MODAL
  UTILITIES

<body>
  <div class="dropzone">  ← initial state
  <div class="app">       ← rendered state
  <div class="modal-bg">  ← rubric modal

<script>
  1. CONFIG    ← edit here
       RUBRIC, SECTION_GROUPS, LABELS, DEFAULTS
  2. PARSING   ← extracts report DOM (rarely changed)
  3. RENDER    ← builds the UI (touch when adding new sections of UI)
  4. BOOTSTRAP ← file loading + ?report= query handler
```

### Testing changes

The tool reads HTML in the browser, so the iteration loop is:

1. Edit `tools/enhance.html`
2. Reload the browser tab (with cache disabled in devtools is helpful)
3. Drop a sample report or use `?report=path/to/report.html`

A sample report ships in `sample_reports/`. Older format but exercises
most of the same DOM patterns.

For automated sanity-checks:

```bash
# Extract embedded JS and syntax-check
python3 -c "
import re
with open('tools/enhance.html') as f: t = f.read()
m = re.search(r'<script[^>]*>(.*?)</script>', t, re.DOTALL)
open('/tmp/enhance.js','w').write(m.group(1))
" && node --check /tmp/enhance.js
```

Visual changes need eyeballs — there's no automated regression suite
for the viewer (yet). If you add one, drop it in
`tests/test_viewer.js` and we'll wire it into CI.
