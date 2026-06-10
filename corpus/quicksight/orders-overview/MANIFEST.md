# quicksight / orders-overview

The QuickSight "Orders Overview" analysis + "Orders Enriched" dataset export
pair from the quicksight-to-sigma plugin fixtures (referenced, not duplicated).
Synthetic CSA.TJ retail data; the dataset is a CustomSql physical table joining
the star schema.

## Artifacts (in plugin fixtures/)

| File | What it is |
|---|---|
| `orders-overview-analysis.json` | DescribeAnalysisDefinition: 1 sheet, 5 visuals (2 KPI, bar, line, pie/donut), 2 CalculatedFields, GridLayout |
| `dataset-orders-enriched.json` | DescribeDataSet: CustomSql physical table (20 columns), DIRECT_QUERY |

## Features exercised

- Analysis + dataset pairing via DataSetArn
- PhysicalTable.CustomSql → Sigma Custom SQL element (`[Custom SQL/COL]` formulas)
- CalculatedFields → calc cols (`{NET_PROFIT}/{NET_REVENUE}`; `ifelse(...)` → `If(...)`)
- Display-name formatting (ORDER_ID → "Order Id")

## Converter

`mcp__sigma-data-model__convert_quicksight_to_sigma` with
`files=[{name, content}, {name, content}]` (both fixture files), empty
connection/database/schema.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/quicksight-to-sigma/skills/quicksight-to-sigma/fixtures/orders-overview-analysis.json", "format": "json"},
    {"path": "../../../plugins/quicksight-to-sigma/skills/quicksight-to-sigma/fixtures/dataset-orders-enriched.json", "format": "json"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 1,
      "columns": 22,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": ["Orders Enriched"]
    }
  }
}
```
