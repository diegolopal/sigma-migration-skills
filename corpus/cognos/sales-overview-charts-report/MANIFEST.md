# cognos / sales-overview-charts-report

The "Sales Overview (charts)" Cognos report-spec XML from the cognos-to-sigma
plugin fixtures (referenced, not duplicated): RAVE2 vizControl charts + lists +
a tiled map over the Fred/GO sales data module — the chart-translation
regression case (kpis, bar/line/pie/combo, region-map).

## Converter

The in-repo converter (report path emits a Sigma **workbook** spec, not a DM):

```
cd plugins/cognos-to-sigma/skills/cognos-to-sigma/converter
npm run --silent convert ../fixtures/sales-overview-charts.report.xml > workbook.json
```

The golden wraps stdout + stderr stats/warnings as `{workbook, stats, warnings}`.
Note the workbook references `<DM_ID>` — remap with the skill's
`remap-wb-to-dm-ids.mjs` before posting.

## Features exercised

- report XML → workbook: 8 KPI charts, 2 bar, 1 line, 1 pie, 1 combo,
  1 tiledmap → region-map, 3 tables (17 elements on 1 page)
- col-formula prefix `[TABLE_TAIL/Col]`, chart slot → axis mapping
- non-simple ?param? filters flagged (42 warnings: re-create as Sigma
  element/page filters)

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/sales-overview-charts.report.xml", "format": "xml"},
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/go-sales-performance.report.xml", "format": "xml"},
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/banking-risk-crosstab.report.xml", "format": "xml"}
  ],
  "goldens": {
    "workbook.json": {
      "pages": 1,
      "elements": 17,
      "columns": 28,
      "warnings": 42
    }
  }
}
```
