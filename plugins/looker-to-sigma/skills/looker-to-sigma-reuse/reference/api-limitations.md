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

## General

- Content-Type for spec PUT must be `application/yaml`
- Content-Type for spec GET returns YAML by default
- PUT replaces the ENTIRE spec -- there's no PATCH for individual elements
- Workbook must exist first (POST /v2/workbooks) before you can PUT its spec
- Page IDs are auto-generated on workbook creation -- GET /v2/workbooks/{id}/pages to retrieve
