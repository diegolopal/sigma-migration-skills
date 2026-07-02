# Composition, fidelity & spec-gotcha recipe — turning a correct migration into a *good* one

> A mechanically-correct migration (0 error columns) can still ship visually empty and
> numerically wrong. This ref captures the composition pass, the value-fidelity rules, and
> the spec/API gotchas that otherwise cost round-trips. Pair it with `operating-contract.md`.
> **Style fields** are documented in `sigma-workbooks/reference/specification/styling.md`;
> this adds the migration workflow and the failure modes that doc doesn't teach.

## When to run a composition pass
Whenever the source dashboard has visual sections (containers/zones with headers) — i.e.
almost always for a report-style dashboard. Skip only for a bare single-table extract.
**Fidelity to the source wins** — mirror its section structure and brand, not a house style.
Signature of a page that needs it (catch on the Phase 5b render): every tile the same width
stacked in one column; >40% of the page empty; the title invisible; source viz missing.

## The composition recipe (verified to render on `/v2/workbooks/{id}/spec` PUT)
1. **Workbook theme** — top-level `themeName: Light` + `themeOverrides`: `borderRadius: round`,
   `hasCards: hidden` (so *you* control which elements get card chrome), and
   `categoricalScheme: [...]` — the **only** spec path to donut/pie slice colors (per-element
   `color.scheme` is silently dropped on donut/pie).
2. **Hero strip** — a full-width `kind: container` with `style.backgroundColor` holding the
   title text. This is the real full-width bar; a text element alone cannot make one (below).
3. **Section panels** — one white `container` per source section, each opening with a **nested**
   colored `container` header bar (nested `<GridContainer>` works).
4. **Stat cards** — mirror the source card grouping. A source "2-value" card → one card container
   holding a label text + two `kpi-chart`s side-by-side, each with a grey subtitle. Set each
   KPI's value-column `name: ' '` (single space) so its own title doesn't duplicate the label.
5. **Number formats** — money `$,.0f`; compact `$,.2s` when two values share a narrow half-card.

Donut specifics: `holeValue:{id:<a column whose id ≠ value's>}` puts the **centre total** in the
ring; `legend:{visibility:hidden}` on donuts that share a legend with a sibling (show it once).

**Extract brand colors from the source file** (grep `<style>`/`format`/`run` for `#`-hex near the
title worksheets and dashboard style); apply via `themeOverrides` + the hero/section bars. A generic
blue reads as "close but not their brand." (`scan-customer-style.rb` can supply org-level defaults.)

## Value-fidelity — why migrated numbers come out wrong
A KPI can be off by orders of magnitude if you sum a raw column instead of translating the calc.

- **KPIs are frequently parameter/ratio/LOD-driven, not `SUM(col)`.** Resolve each field's
  `<calculation formula>` (incl. `[Parameters].[…]` refs and FIXED-LOD) and emit the real kind:
  a constant param → a value/control ref; a ratio → division; an LOD → a grouping. Summing a raw
  column where the source computes a ratio/param yields garbage (e.g. a 5-digit "ROI").
- **Prefer the source's materialized validated calc columns.** Migrations often already carry the
  source's validated calcs as columns (e.g. `…(copy)…` fields). Summing *those* reproduces the
  per-row logic (including per-row rate lookups) exactly — far better than re-deriving `SUM(x)*param`.
  Caveat: those materialized columns' **display names can be mislabeled** (a field tagged `(NR)` may
  hold the `NR+MD` value) — trust the *values* against the source, not the name.
- **Use the source's exact aggregate + population.** `Count` vs `CountDistinct` changes the number;
  a numerator and denominator running over different filtered populations (e.g. cost excludes a
  category but the divisor doesn't) makes averages/ratios drift. Match each measure's aggregate AND
  the rows it runs over.
- **Apply the source's dashboard/period filters.** If the source scopes the dashboard to a period
  (often via a parameter-driven boolean calc, sometimes materialized as an `In Report Period`-style
  column), apply it to the built tables/elements — and **verify** the model's existing filter state
  (`GET /columns`, read element `filters`) rather than assuming it is or isn't applied.
- **Pick the date-*typed* column, not its text twin.** A model may carry both a text and a datetime
  version of a date field; `DateTrunc("month", <text col>)` fails with **"Argument 2 invalid for
  function"** and collapses a time series into one error bar. Resolve to the datetime column or cast.

## Controls & parameters rarely survive — rebuild them
Migrations commonly drop the interactive layer. Rebuild from the source's parameters + quick filters:
- **List control**: `controlType: list` + double-nested `source: {kind: source, source: {kind: table,
  elementId}, columnId}` + `filters: [{source: {kind: table, elementId}, columnId}]` + flat
  `mode`/`selectionMode`/`values`.
- **Date-range control**: `controlType: date-range`, `mode: between` (+ optional `startDate`/`endDate`;
  other modes carry their own flat fields).
- Wire `filters` to the **base tables** so the control filters workbook-wide.
- **Parameters → controls, wired into the formulas** (number controls are safe to reference by
  `[ControlId]` in arithmetic; only date/list control refs hit the variant bug). Don't hardcode.
- Gate idea: source has parameters/quick-filters but the workbook has 0 controls → flag it.

## Spec/API gotchas (each avoids a wasted round-trip)
- **`/spec` GET returns YAML; PUT takes JSON.**
- **A rejected PUT is atomic** — nothing is written. Guard every write (assert `pages` exists; assert
  the prior layout string is unchanged when you only meant to touch formulas) so a bad token or field
  can never half-corrupt a workbook. A missing element is often a *silent earlier 400*, not a render bug.
- **pivot `values` is a `string[]`** of column ids, not `[{id}]`. `rowsBy`/`columnsBy` ARE `[{id, sort?}]`.
- **Text inline HTML is whitelisted:** only `<u> <sub> <sup> <span> <a>`. **`<div>` is rejected.**
  `<span style>` allows only `color`/`background-color`/`font-size`/`font-family`. Centre/right via
  `<p style="text-align: center|right">`; **`text-align: left` is rejected** (default) — use a plain
  span/heading. A full-width colored bar is only achievable via a `container` `style.backgroundColor`.
- **Donut/pie:** `color.scheme` is silently stripped (use `themeOverrides.categoricalScheme`);
  `holeValue.id == value.id` silently drops the element (use a distinct column).
- **KPI title suppression:** only `name: ' '` (single space) works; omitting re-derives the title.
- **Bar/line `color`** = `{by, column, scheme}`, not a bare `{scheme}`. Single-series charts omit it.
- **Never bulk-rename a live column's display name** — formulas reference columns by `[Element/Name]`,
  so a rename throws `Dependency not found`. Rename only element-local pivot columns, or set friendly
  names at build time on freshly-created columns.
- **Sigma auto-appends unplaced elements to the layout on save.** To delete an element, remove BOTH the
  element AND its (possibly auto-added) `<LayoutElement>` ref, or the next PUT 400s on a dangling ref.
- **API tokens are short-lived** — re-auth immediately before each GET/PUT/export.

## Wiring into the converter (the actual leverage)
1. **Composition pass (Phase 5e)** — build theme + panels + bars + carded KPIs from the parsed zones;
   this is the reference output for the composition-layer epic.
2. **Fix the layout fallback** so it never emits a half-width single-column stack; fix
   `build-dashboard-layout.rb`'s bottom-band safety net (its `kind` check never matches real chart
   kinds like `bar-chart`/`kpi-chart`/`table`, so unmatched tiles vanish silently).
3. **Hard visual + value gates** (see `assert-phase6-ran.rb` gate 8b, now enforced by default):
   fail — not warn — on empty/low-fill pages and on KPI numbers that don't match the source.
4. **White-title trap:** when a source title uses white text meant for a header band, build the band
   (a colored container) OR recolor — never emit invisible white-on-light.
5. **Reconstruct no-standalone-view viz** from the model (donuts/trends/matrices) instead of dropping.
