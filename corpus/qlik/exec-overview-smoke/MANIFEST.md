# qlik / exec-overview-smoke

Qlik Cloud "Exec Overview" smoke-test app discovery output (synthetic CSA
retail star: OrderFact + Customer/Product/Store/Calendar/Promo), captured from
a live qlik-to-sigma skill run. `converter-input.json` is the assembled
converter feed — Engine-API tables/fields plus 13 master measures — i.e. the
**Qlik MODEL**, which is what the converter must always be fed (never the raw
warehouse schema).

A second, hand-curated example of the same input format lives in the plugin:
[`refs/example-converter-input.json`](../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/refs/example-converter-input.json).

## Features exercised

- REST/Engine "tables" format (tables + fields arrays)
- Shared field names → relationships (5 dims → OrderFact on *_KEY)
- Master measures → metrics incl. a Set Analysis expression
  (`Sum({<IS_HOLIDAY={1}>} NET_REVENUE)` → `Sum(If([Is Holiday]=1, [Net Revenue], 0))`)
- Derived "<Dim> View" elements with cross-element passthroughs
- Currency/percent format inference from measure names

## Converter

`mcp__sigma-data-model__convert_qlik_to_sigma` with
`model_json=<converter-input.json>`, empty connection/database/schema.

## Expectations

```json
{
  "artifacts": [
    {"path": "converter-input.json", "format": "json"},
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/refs/example-converter-input.json", "format": "json"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 11,
      "columns": 231,
      "metrics": 13,
      "relationships": 5,
      "warnings": 0,
      "element_names": ["ORDERFACT", "CUSTOMER", "PRODUCT", "STORE", "CALENDAR", "PROMO", "Customer View", "Product View", "Store View", "Calendar View", "Promo View"]
    }
  }
}
```
