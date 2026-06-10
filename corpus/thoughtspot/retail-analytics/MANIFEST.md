# thoughtspot / retail-analytics

ThoughtSpot "Retail Analytics" model + "Sales Overview" liveboard TML, exported
2026-06-04 from a ThoughtSpot trial (team2) over the synthetic CSA.TJ retail
star schema.

## Artifacts

| File | What it is |
|---|---|
| `retail_model_export.tml` | Model TML: 6 model_tables, 5 joins, 4 formulas, 63 columns (ATTRIBUTE/MEASURE + aggregations) |
| `retail_liveboard.tml` | Liveboard TML: 5 visualizations (KPI, column, line, pie, table) — workbook-side input |

## Features exercised

- `model:` TML format (model_tables + joins with `[TABLE::COL]` ON clauses, MANY_TO_ONE)
- formulas: `safe_divide` → null-safe division, `if/then/else` → `If()`,
  `in {..}` → `In()`, `count` → metric
- Column-level `aggregation: SUM/AVERAGE` → element metrics
- Attribute vs measure split; derived "Order Fact View" with cross-element refs

## Converter

`mcp__sigma-data-model__convert_thoughtspot_to_sigma` with
`tml_yaml=<retail_model_export.tml>`, empty connection/database/schema.
(The liveboard is consumed by the thoughtspot-to-sigma skill's workbook
builder, not this converter — no golden for it.)

## Known parity reference (live build 2026-06-04)

Liveboard ground truth: Total Net Revenue KPI = **108,797.85** (see
`migration_manifest.json` ground_truth in the original
~/thoughtspot-migration capture; drifts if CSA.TJ data changes).

## Expectations

```json
{
  "artifacts": [
    {"path": "retail_model_export.tml", "format": "yaml"},
    {"path": "retail_liveboard.tml", "format": "yaml"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 7,
      "columns": 124,
      "metrics": 15,
      "relationships": 5,
      "warnings": 0,
      "element_names": ["Order Fact", "Customer Dim", "Product Dim", "Store Dim", "Date Dim", "Promo Dim", "Order Fact View"],
      "relationship_names": ["CUSTOMER_DIM", "DATE_DIM", "PRODUCT_DIM", "PROMO_DIM", "STORE_DIM"]
    }
  }
}
```
