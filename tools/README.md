# tools/

Static utilities that wrap or post-process pg_collector output.
None of these modify `pg_collector.sql`.

## `enhance.html` — modern viewer

One file. ~110 KB. No dependencies — no Node, no Python, no npm, no CDN,
no `<script src>`, no `import`, no build step. Pure HTML + CSS +
browser-native JavaScript. Works offline forever.

Drop a `pg_collector_*.html` report onto it (or pass `?report=URL`) and
it renders a modern UI on top of the existing report DOM:

- A traffic light at the top: the lamp for the worst severity present is
  lit, severities that have findings but are not the worst glow dim, and
  empty sockets stay dark — so the verdict lands before any number does
- One-click severity filter: click a lamp (or a chip) and the findings,
  the sidebar and the detail sections all collapse to that severity
- Show the SQL behind any section: load `pg_collector.sql` alongside the
  report (drop both on the page, or pass `&script=`) and each section gains a
  disclosure holding the script text between that section's anchor and the
  next, psql meta-commands stripped and SQL comments kept. Nothing is
  pre-baked, so it stays correct across branches and PG majors
- Severity-grouped findings with rationale tooltips
- Sticky sidebar with section grouping, search, and scroll-spy
- Restyled tables, dark/light/auto theme, in-browser only (no upload)

### Open it

The fastest path:

```bash
xdg-open tools/enhance.html             # or just double-click the file
```

Then drag-and-drop a `pg_collector_*.html` onto the page. That's it.
Nothing to install, nothing to run.

If you'd like to use the `?report=URL` query-param to auto-load a
specific report (handy for sharing links, or previewing a CI artifact),
that path needs *some* HTTP server because the browser blocks
cross-origin file fetches. Any static server works — pick whatever
you have:

```bash
python3 -m http.server 8770       # if you have Python
busybox httpd -f -p 8770          # if you have busybox
ruby -run -e httpd . -p 8770      # if you have Ruby
# … anything that serves files over HTTP
```

Then visit `http://127.0.0.1:8770/tools/enhance.html?report=/path/to/report.html`.

### Customizing it

The file is laid out so common tweaks happen in a single `CONFIG` region
of the `<script>` block. Each customization point is documented inline
with a comment block. The file's top comment header lists every entry
point — open `tools/enhance.html` and search for the matching section.

> **Adding a new section to `pg_collector.sql` and making it render
> well in the viewer?** See [`CUSTOMIZING.md`](CUSTOMIZING.md) — it walks
> through the end-to-end flow with a worked example.

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
  initialFilter: null,                // 'crit' | 'warn' | 'note' | null (all)
  hideEmptySections: true,            // suppress "No X found" sections
  initialTheme: 'auto',               // 'auto' | 'light' | 'dark' | <custom>
};
```

Set `initialFilter: 'crit'` to have the report open showing only the
critical findings and only the sections they point at — useful if you
hand the viewer to someone who should triage before they browse.

#### Recipe: recolor the traffic light

The lamps are deliberately theme-independent: they have to read as
emitted light against the dark housing, so they are defined once in the
base `:root` and inherited by every `[data-theme]` block.

```css
  --lamp-red:   #e5484d; --lamp-red-dim:   #58242a; --lamp-red-glow:   rgba(229,72,77,.6);
  --lamp-amber: #f5a524; --lamp-amber-dim: #553a10; --lamp-amber-glow: rgba(245,165,36,.55);
  --lamp-note:  #4e9bea; --lamp-note-dim:  #1b3450; --lamp-note-glow:  rgba(78,155,234,.5);
  --lamp-green: #30a46c;                            --lamp-green-glow: rgba(48,164,108,.5);
  --lamp-housing: #0c1017;   /* the dark surround */
  --lamp-off:     #272e3b;   /* a socket with nothing in it */
```

The `-dim` variant is the lamp when that severity has findings but a
worse one governs; the `-glow` variant is the halo on the lit lamp.
The third lamp is blue rather than green because the viewer already ties
the notice severity to blue everywhere else — green is reserved for the
all-clear state, which takes the same bottom socket when nothing fired.
Recolor `--lamp-note` to `--lamp-green` if you prefer a literal RAG
traffic light.

The headline above the lamps comes from `LABELS.verdictTitle` and
`LABELS.verdictBlurb`, keyed by `crit` / `warn` / `note` / `ok`:

```js
  verdictTitle: { crit: 'Action required', warn: 'Needs attention',
                  note: 'Minor notices only', ok: 'All clear' },
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
  TRAFFIC LIGHT        ← verdict banner, lamps, filter chips
  SEV BLOCKS
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

There is no build step. The iteration loop is:

1. Edit `tools/enhance.html`.
2. Reload the browser tab (devtools "disable cache" is helpful).
3. Drop a sample report or use `?report=path/to/report.html`.

A sample report ships in `sample_reports/`. Older format but exercises
most of the same DOM patterns. Recent CI runs leave fresh reports under
`tests/artifacts/<timestamp>/report.html`.

#### Optional: pre-reload syntax check

If you want to catch JS syntax errors without leaving the terminal,
any JavaScript engine you already have on the box works. None of these
are required — reloading the browser with devtools open shows the same
errors. Examples:

```bash
# Slice the <script> block out and hand that to the engine -- node refuses
# a .html file outright, and the HTML around the script is not valid JS.
sed -n "/^<script>$/,/^<\/script>$/p" tools/enhance.html \
  | sed '1d;$d' > /tmp/enhance.js && node --check /tmp/enhance.js
```

Visual changes need eyeballs — there's no automated regression suite
for the viewer (yet). If you add one, drop it in
`tests/test_viewer.js` and we'll wire it into CI.

#### Regenerating the README GIF

The GIFs in the root README -- `img/run_and_view.gif`,
`img/sample_report_viewer.gif` and `img/enhance_traffic_light.gif` (the
filtering-only cut, kept for reference) -- are driven by `tools/gif-capture.html`,
a maintainer-only harness that loads the viewer in an iframe and replays
a fixed storyboard. Frame N replays actions 1..N from a cold load, so
frames never depend on capture timing. The full chromium + ffmpeg recipe
is in a comment at the top of that file.

It takes three query parameters: `step` (which frame), `story`
(`traffic`, `sample` or `endtoend`), and `r` (which report to load). The
`endtoend` story opens with a terminal overlay whose text is a verbatim
capture of a real run against `postgres:19beta3` -- stored in the `TERMINAL`
array, re-capture it rather than editing it by hand -- then hands over to the
viewer. The sample
story's last frames are captured against the PG16, PG15 and PG14 reports
in turn, which is how one GIF shows the viewer handling every major.
Edit the `TRAFFIC` or `SAMPLE` array to change what is demonstrated.

### What this viewer is *not*

To keep the lightweight promise, some things are deliberately out of scope:

- **No frontend framework** (React/Vue/Svelte). Plain DOM and `<details>`.
- **No charting library**. Bar charts and sparklines would be nice but
  add 100 KB+ as soon as you bring in a library.
- **No bundler / npm**. The file is the artifact.
- **No telemetry, no remote calls**. The page never makes a network
  request except via your explicit `?report=URL`. Drag-drop processing
  is 100% local.

If you want any of those, fork and add them — but consider whether the
110 KB / zero-deps property is worth keeping first.
