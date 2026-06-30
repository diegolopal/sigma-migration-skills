# Insight & dashboard → Sigma element mapping (research spike, June 2026)

## Insights = `visualizationObject`

Each insight has:
- `visualizationUrl` — the chart type, a `local:<type>` token.
- `buckets[]` — each with a `localIdentifier` (`measures`, `view`, `stack`,
  `segment`, `secondary_measures`, `trend`, …) and `items[]` (measures =
  metric/fact refs with their own `localIdentifier` + aggregation; attributes =
  dimension refs).
- `filters[]` — measure-value / attribute / ranking / date filters (outside the
  buckets).
- `sorts` and `properties` (display config).

Bucket → Sigma channel is the same idea as Cognos `vizControl` slot → axis:
`measures`→values, `view`→category/x-axis, `stack`/`segment`→color/series.

## `visualizationUrl` → Sigma element

| `local:` type | Sigma element | Notes |
|---|---|---|
| `headline` | `kpi-chart` | one (or two, with secondary) measures; **set `name: ' '`** when a label sits above it (see sigma-workbooks) |
| `table` | `table` | aggregated → carry `groupings` |
| `pivot` (`table` w/ rows+cols) | `pivot-table` | `rowsBy` / `columnsBy` / `values` |
| `column` | `bar-chart` | vertical (orientation omitted) |
| `bar` | `bar-chart` | `orientation: horizontal` |
| `line` | `line-chart` | `view`→x, `trend`/`segment`→series |
| `area` | `area-chart` | stacking from bucket config |
| `combo` / `combo2` | `combo-chart` | measures split across `yAxis` / `yAxis2` |
| `pie` | `pie-chart` | |
| `donut` | `donut-chart` | distinct hole-value column (avoid the collision bug) |
| `scatter` | `scatter` | x/y measures |
| `bubble` | `scatter` w/ size | |
| `heatmap` | heatmap / pivot w/ conditional format | |
| `treemap` | flag → table | no clean Sigma equivalent yet |
| `geo` / `pushpin` | region-map / point-map | maps reference |
| `funnel` / `pyramid` / `sankey` / `dependencywheel` / `waterfall` / `repeater` | **flag → table** | surfaced as UNHANDLED, not faked |

Chart authoring defers entirely to the **sigma-workbooks** skill (channels,
formula qualification, layout, the `name: ' '` KPI-title rule, theming). Reuse
the shared `build-charts-from-signals` + `decollide_bands` + the mandatory
visual-QA gate.

## Dashboards = `analyticalDashboard`

```jsonc
{
  "layout": {
    "sections": [
      { "items": [ { "size": {...}, "widget": { /* insight ref | kpi | richText */ } } ] }
    ]
  },
  "filterContext": { /* attribute/date filters applied dashboard-wide */ }
}
```

- `layout.sections[].items[].widget` → place each referenced insight as a
  workbook element; `size` (responsive grid width) → Sigma grid columns in the
  page `layout` XML.
- `richText` widgets → `text` elements.
- `filterContext` → Sigma **controls**, scoped to the pages that reference them
  (avoid the over-broad-control trap).
- `ignoreDashboardFilters` on a widget → that element opts out of the control.

## Parity

Each insight is a query; verify its aggregated result against the same
warehouse (post-and-readback + assert-parity), exactly like the other
converters. Dashboard filter context must be applied when checking, or totals
won't match.
