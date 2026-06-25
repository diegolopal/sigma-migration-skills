# tableau / partner-crosstab-controls

Hand-authored minimal `.twb` reproducing the three EDNA "Partner Landscape"
regressions a customer reported 2026-06-25 (a 10 MB, 86-worksheet partner
bookings workbook whose data we don't have, so this fixture mirrors the SHAPES
on the live CSA.TJ retail star instead):

1. **Automatic-mark crosstabs built as flat tables.** The customer's two big
   "Metrics by Partner" tables (Partner Name rows × quarter × Measure-Names
   columns + Grand Total) authored with Tableau's DEFAULT `Automatic` mark —
   `parse-twb-layout.rb` only treated `Text`/`Square` marks as crosstabs, so
   they fell through to flat `table`/`kpi`, dropping the grouped column headers
   and Grand Total. (Real EDNA: only 2 of 86 worksheets detected as crosstab;
   ≥28 had dims on both shelves.)
2. **Dashboard quick-filters dropped.** ~40 left-rail filter controls whose
   columns carry NO `caption` attribute (`[none:Customer Geo:nk]`), are
   multi-word, are Tableau GROUPS (`[Partner Level (group)]`), or contain a
   slash (`[Mkt Sourced/Influenced]`). `COL_BY_GUID` registered only
   caption-bearing columns and truncated multi-word names to the first word, and
   `guid_from_param` choked on `(group)` / `(copy)` / `/` — so every shared
   filter resolved to a null caption and `build-charts` skipped all of them
   ("no resolvable column_caption"). (Real EDNA: 0 of 70 shared filters
   resolved → fixed to 70/70.)
3. **Measure-switcher parameter showed raw integer codes.** An integer parameter
   (`Summary $ Choose`, 1→TCV / 2→Product TCV / 3→ACV) whose CASE swaps which
   aggregated FIELD is displayed. The segmented control emitted `labels: []` so
   it rendered as `1 / 2 / 3` instead of the alias labels.

Synthetic XML (no live tenant), modeled on real Tableau 2024.1 `.twb` shapes.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | Synthetic workbook: 1 Automatic-mark crosstab worksheet `Metric Partner Closed Won` (Partner Name rows × Created FYQQ + Measure Names cols), 1 Automatic-mark `Bookings by Quarter Bar` worksheet that is the OVER-FIRE GUARD (Measure Names on cols but the measure VALUES on rows as `[Multiple Values]` → a bar, must NOT be a crosstab), 1 dashboard, a `<shared-view>` with 3 quick filters exercising all the failure modes — caption-less multi-word (`Customer Geo`), a Tableau GROUP (`Partner Level (group)`), and a slash name (`Mkt Sourced/Influenced`) — plus an integer measure-swap parameter (`Summary $ Choose`, 1→TCV / 2→Product TCV / 3→ACV) with value aliases |
| `get-workbook.json`, `master-columns.json` | Minimal discovery fixtures so `build-charts-from-signals.rb` runs offline |
| `chart-specs.json` | PINNED `build-charts-from-signals.rb` output — captures all three fixes in one deterministic artifact (see assertions) |

## Converter

No MCP converter — this case pins the SKILL-script contracts. `$S` =
`plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`:

```
ruby $S/parse-twb-layout.rb workbook-content.twb dashboard-layout.json
ruby $S/build-charts-from-signals.rb --tableau-dir . --layout dashboard-layout.json \
  --meta dashboard-layout-meta.json --master-map master-columns.json \
  --master-element-id master --auto-controls --page-per-worksheet \
  --title "Partner Landscape" --out chart-specs.json
```

`dashboard-layout*.json` / `control-scope.json` are regenerable intermediates
and are not pinned; diff the regenerated `chart-specs.json` against the pinned
copy (deterministic — element ids are name-derived, no randomness).

## Assertions encoded by the pins (`chart-specs.json`)

- **Crosstab → pivot-table (fix 1):** the `Metric Partner Closed Won` worksheet
  (mark `Automatic`, Measure Names on cols) emits a `kind: pivot-table`
  element with `rowsBy` (Partner Name), `columnsBy` (Created FYQQ), and a
  `values` array — NOT a flat `table`.
- **Over-fire guard (fix 1, parse-level):** `parse-twb-layout` sets
  `is_crosstab: true` for `Metric Partner Closed Won` but `is_crosstab: false`
  for `Bookings by Quarter Bar` — the latter carries the Measure-VALUES pill
  (`has_measure_values: true`), so an Automatic-mark multi-measure BAR is not
  misclassified as a crosstab. (Real-world catch from the coverage sweep: a
  public "Barchart of accident factors" sheet was being turned into a pivot.)
- **Quick filters resolved → controls (fix 2):** all three shared filters emit
  `kind: control`, `controlType: list` elements wired to the master — the
  caption-less multi-word `Customer Geo`, the group `Partner Level (g)`, and the
  slash `Mkt Sourced/Influenced` — none dropped as "no resolvable
  column_caption."
- **Param labels (fix 3a):** the `Summary $ Choose` segmented control carries
  `source.values: ["1","2","3"]` AND `source.labels: ["TCV","Product TCV",
  "ACV"]` (from the parameter's value aliases) — never an empty `labels` array.
- **Measure-swap Switch (fix 3b):** the pivot's measure value column is
  `Switch([ctl-param-summary-choose-...], "1", Sum([TCV]), "2",
  Sum([Product TCV]), "3", Sum([ACV]))`, and the referenced `controlId` matches
  the emitted segmented control (no dead control).

## Live validation (CSA.TJ, 2026-06-25)

The same four shapes were built on the live `CSA.TJ.ORDER_FACT` warehouse
(org `tj-wells-1989`, conn `bc0319f8`), POSTed as a DM + workbook, and rendered:
the pivot rendered as a grouped crosstab with a **Grand-total row + column**;
the segmented control rendered with the alias labels; flipping it from
"Net Revenue" → "Quantity" changed the measure column (grand total
119,038 → 1,593) while the static Net Revenue column held — proving the
parameter switches the calculation. Throwaway workbook + DM were deleted after.

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "get-workbook.json", "format": "json"},
    {"path": "master-columns.json", "format": "json"},
    {"path": "chart-specs.json", "format": "json"}
  ]
}
```
