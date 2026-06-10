# Cognos source-format shapes (as observed on real CA 11.x / 12.x samples)

What the converter actually parses. Verified 2026 against IBM sample content on CA on Cloud.

## CA REST endpoints

| Need | Endpoint | Notes |
|---|---|---|
| List a folder | `GET /bi/v1/objects/{id}/items?fields=defaultName,type,id` | `data[]` of `{id,type,defaultName}`; `type` ∈ folder/module/report/exploration/reportView/dataSet2 |
| **Data Module JSON** | `GET /bi/v1/metadata/modules/{id}` | the spec. `/modules/{id}` returns EMPTY — wrong one. |
| **Report-spec XML** | `GET /bi/v1/objects/{id}?fields=specification` | `data[0].specification` is the report XML string (schema 17.x) |
| Data server connections | Manage → Data server connections | relational sources (e.g. GOSALES); warehouse-backed modules build on these |

Auth: session cookie + `X-XSRF-Token`. Base path is **`/bi/v1`** (not `/api/v1`).

## Data Module JSON (`metadata/modules/{id}`)

```jsonc
{
  "version": "24.0", "identifier": "…", "label": "…",
  "useSpec": [ { "identifier": "M1", "type": "file"|"dataSource", "searchPath": "…", … } ],
  "querySubject": [
    {
      "identifier": "Sales", "label": "Sales",
      "ref": ["M1.Sales"],                       // physical source: useSpec M1, table/sheet "Sales"
      "item": [
        { "queryItem": { "identifier": "Quantity", "label": "Quantity",
                         "expression": "Quantity",        // BARE identifier = plain column
                         "usage": "fact", "regularAggregate": "total",  // fact + agg → metric
                         "datatype": "…", "format": "{…}" } },
        { "queryItem": { "identifier": "Margin", "expression": "[Sales].[Revenue]-[Sales].[Cost]", … } }  // calc
      ]
    }
  ],
  "relationship": [
    { "left":  { "ref": "Sales", "mincard": "one", "maxcard": "many" },
      "right": { "ref": "Product", "mincard": "one", "maxcard": "one" },
      "link":  [ { "leftRef": "Product_key", "rightRef": "Product_key", "comparisonOperator": "equalTo" } ] }
  ],
  "calculation": [ … ],   // model-level calcs (separate from per-subject items)
  "filter": [ … ]
}
```

Key facts the converter relies on:
- **Table source = `querySubject.ref` tail** (`"M1.Sales"` → `Sales`), NOT `definition.dbQuery` (that's an older/authored shape — also supported as a fallback). `useSpec` resolves M1 to a DB source or an uploaded file.
- **Plain column** = a **bare-identifier** expression (`"Quantity"`) or a self-subject ref (`[Sales].[Quantity]`). Anything else = a calculation.
- **Measure** = `usage:"fact"`/`"measure"` + a `regularAggregate` other than `none`.
- **Relationship join columns** come directly from `link[].leftRef`/`rightRef` (+ `mincard/maxcard`) — no expression to parse. Source element = the **`many`** side.
- **File-backed** modules (`useSpec.type:"file"`, an uploaded `.xlsx`) ⇒ land the data in the warehouse first; the original file is NOT re-downloadable via REST (stored copies are proprietary `.pq`).
- Layered modules expose **base + presentation** query subjects; both convert (a dedupe-to-physical-table pass is a roadmap refinement).

## Report-spec XML (`objects/{id}?fields=specification`)

```xml
<report xmlns="http://developer.cognos.com/schemas/report/17.5/">
  <queries><query name="qMain"><source><model/></source>
    <selection>
      <dataItem name="Country"><expression>[C].[Module].[sheet1].[Country]</expression></dataItem>
      <dataItem name="Swap Measure"><expression># prompt('pColumn','token','[…].[Revenue]') #</expression></dataItem>
      <dataItem name="YtY Revenue"><expression>(([CYQRev]-[PYQRev])/abs([PYQRev]))</expression></dataItem>
    </selection>
    <detailFilters><detailFilter><filterExpression>[Year]=2023</filterExpression></detailFilter></detailFilters>
  </query></queries>
  <layouts><layout><reportPages><page name="Page1"><pageBody><contents>
    <list refQuery="qMain"><listColumns><listColumn>
      <listColumnBody><contents><textItem><dataSource><dataItemValue refDataItem="Country"/></dataSource></textItem></contents></listColumnBody>
    </listColumn>…</listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts>
</report>
```

Key facts:
- Each `<query>` holds `<dataItem name expression>`; the dominant model **subject** is parsed from a `[C].[Module].[Subject].[Col]` ref → used as the Sigma table-element source name.
- Each `<list refQuery=Q>` → a Sigma `table` element; its columns are the `dataItemValue@refDataItem`s.
- `Summary(x)` / `Total(x)` list columns = layout aggregate footers → `Sum([x])` etc.
- `prompt('p')` in any expression → a Sigma control; `#…#` macros → flagged (see `expression-dsl.md`).
- Filters are surfaced as warnings to re-create.
- **Crosstabs (`<crosstab>`) → Sigma pivot-table** (supported, live-validated): `<crosstabRows>`/`<crosstabColumns>` → `crosstabNodeMember@refDataItem` give the row/column edge dims (skip `Total(...)` grand-total nodes); the measure is `<crosstabCorner><dataItemLabel@refDataItem>`. Maps to `rowsBy:[{id}]` · `columnsBy:[{id}]` · `values:[<colId string>]` (note: **values are bare id strings, rowsBy/columnsBy are `{id}` objects**; measure column formula = `Sum(<ref>)`).
- Charts (RAVE2 `<visualization>`) live in dashboards (separate JSON), not report XML — roadmap.
