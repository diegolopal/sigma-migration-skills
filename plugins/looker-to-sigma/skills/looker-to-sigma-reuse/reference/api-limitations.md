# Sigma Workbook Spec API Limitations

Known limitations discovered through migration testing. Updated as new issues are found.

## Controls

| controlType | Supported via API? | Notes |
|---|---|---|
| `number` | YES | Only type that works for creating new controls |
| `text-input` | NO | Spec PUT returns "Invalid kind: control" |
| `list` | NO | Same error regardless of mode (single-select, multi-select) |
| `date-range` | NO | Same error |
| `top-n` | NO | Same error |

**Workaround:** Create the workbook with numeric controls only via API. Add text/list/date controls manually in the Sigma UI after the spec is applied.

**Note:** Existing workbooks that already HAVE text/list/date controls can be read via GET /spec (they appear correctly in the exported YAML). But you cannot PUT them back -- the API only accepts `number` for new control creation.

## Filters

| Filter type | Supported? | Notes |
|---|---|---|
| Text equality on text columns | YES | `kind: list`, `mode: include`, `values: ["somestring"]` |
| Numeric filters | YES | Via controls |
| Boolean filters | NO | PUT succeeds but UI shows "Invalid filter". Always invalid regardless of value format (`true`, `"true"`, `True`, `"True"`) |

**Workaround:** Never include boolean filters in the spec. Document them in the migration summary as "add manually in UI".

## Data Types

| Feature | Supported? | Notes |
|---|---|---|
| VARIANT/JSON columns | Partial | Column displays as raw JSON text. Cannot extract fields with formulas (`CallVariant()`, `Variant()`, `JsonExtractText()` all fail). Use UI "Extract Columns" to split into individual columns. |
| Cross-element formulas | YES | `[VisibleElement/RelationshipTargetName/Column Display Name]` |
| Calculated columns | YES | Standard Sigma formulas work (If, Concat, etc.) |

## Element Visibility

| Behavior | Notes |
|---|---|
| API returns hidden elements | `GET /v2/dataModels/{id}/spec` returns ALL elements, visible and hidden. No filtering. |
| `visibleAsSource: false` | Present on hidden elements; omitted on visible ones (default is true) |
| Creating workbooks with hidden elements | PUT succeeds -- the API does not validate visibility. But users cannot interact with the workbook in the UI. |

## Layout

| Feature | Notes |
|---|---|
| LayoutElement tag | Use `<LayoutElement elementId="..." gridColumn="..." gridRow="..."/>` |
| Grid system | 24 columns (`repeat(24, 1fr)`), rows are auto-sized |
| Element height | Controlled by gridRow span (e.g., `1 / 23` = 22 rows tall) |

## Metrics in Workbook Specs

| Syntax | Context | Notes |
|---|---|---|
| `[Metrics/Metric Name]` | Workbook spec YAML `formula:` fields | **CORRECT** -- use the metric display name |
| `metric('id')` | Sigma MCP query tool (SQL context only) | Does NOT work in YAML specs |

**Rule:** Always use `[Metrics/Display Name]` in workbook specs. Never use `metric('id')`.

## Groupings in Workbook Specs

Groupings require `id`, `groupBy`, and `calculations` fields:

```yaml
groupings:
  - id: grp_team          # unique id for the grouping
    groupBy:
      - column_id_1       # column IDs (from the `columns` array) to group by
      - column_id_2
    calculations:
      - metric_col_id_1   # column IDs that are aggregations within this group
      - metric_col_id_2
```

**Common errors:**
- `groupings[0].id: Duplicate id` -- the grouping `id` must NOT reuse a column ID
- `groupings[0].id: Invalid string: undefined` -- the grouping needs an `id` field; `columnId` is not a valid key

## Lookups Between Elements

| Pattern | Supported? | Notes |
|---|---|---|
| Lookup to raw columns in another element | YES | Works when target columns are direct warehouse columns |
| Lookup to calculated/metric columns (in a grouping) | PARTIAL | PUT succeeds but UI may show "Unknown column". Configure manually in UI if this happens |

**Syntax:** `Lookup([TargetElement/Column Name], [TargetElement/Key Column], [ThisElement/Key Column])`

**Tips:**
- Use simple column names without special characters (`%`, `/`) in the target element to avoid resolution issues
- The target element must be on the same page
- Hidden elements (`hidden="true"` in layout) can still be Lookup targets

## Merge Results (Looker) → Sigma Pattern

Looker merge results combine queries from different explores by a shared key. In Sigma:

1. Create **Element 1** (main table) from DM A with the static/dimension data
2. Create **Element 2** (hidden helper) from DM B, grouped by the shared key, with metrics as calculations
3. Add Lookup columns on Element 1 referencing Element 2
4. Hide Element 2 in layout: `<LayoutElement elementId="..." hidden="true"/>`

**Alternative:** If a single DM already consolidates both data sources (e.g., "Salesloft Account Health"), prefer that over a multi-element Lookup approach.

## Draft vs Published Version Sync

| Action | Updates Draft? | Updates Published? |
|---|---|---|
| `PUT /spec` only | YES | NO |
| `PUT /spec` then `POST /publish` | NO (draft keeps old state) | YES |
| `PUT /spec`, `POST /publish`, `PUT /spec` again | YES (second PUT fixes it) | YES |

**Rule:** After publishing, always re-apply the spec with another `PUT /spec` to keep the draft in sync. Otherwise users see stale content in edit mode and must "Revert to published" manually.

## General

- Content-Type for spec PUT must be `application/yaml`
- Content-Type for spec GET returns YAML by default
- PUT replaces the ENTIRE spec -- there's no PATCH for individual elements
- Workbook must exist first (POST /v2/workbooks) before you can PUT its spec
- Page IDs are auto-generated on workbook creation -- GET /v2/workbooks/{id}/pages to retrieve
- Every `filters` entry in a spec element requires an `id` field -- omitting it causes "Invalid string: undefined"
