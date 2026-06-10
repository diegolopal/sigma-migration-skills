# powerbi / report-classic-employee-dashboard

A LEGACY single-file Power BI report layout ("EMPLOYEE DASHBOARD", synthetic
CSA.TJ workforce data, extracted 2026-06-07 from a Fabric My-workspace via
`getDefinition`). This is the **classic `report.json` format** — one file with
a `sections[]` array — NOT the exploded PBIR folder format. Both formats exist
in the wild; the powerbi-to-sigma skill's `extract-report-classic.py` handles
this one.

`definition.pbir` is included for the dataset-reference shape
(`semanticmodelid` sanitized to zeros).

## Features exercised

- Classic `sections[].visualContainers[].config` (stringified-JSON-in-JSON) parsing
- Visual types: barChart, azureMap, textbox, lineChart, pieChart
- Theme resource reference (StaticResources)

## Converter

No single MCP tool — the report layer is consumed by the powerbi-to-sigma
skill's workbook builder scripts (model layer comes from the paired `.bim`
via `convert_powerbi_to_sigma`). No golden; the expectations below pin the
artifact structure (1 section, 5 visuals).

## Expectations

```json
{
  "artifacts": [
    {"path": "report.json", "format": "json"},
    {"path": "definition.pbir", "format": "json"},
    {"path": "StaticResources__SharedResources__BaseThemes__CY26SU05.json", "format": "json"}
  ],
  "goldens": {}
}
```
