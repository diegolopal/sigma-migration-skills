# powerbi / report-pbir-retail-performance

A MODERN exploded **PBIR** report definition ("Retail Performance & Trends",
synthetic retail data, extracted 2026-06-07 from Fabric via `getDefinition`).
Flattened here with `__` standing in for `/` in the original Fabric part paths
(e.g. `definition__pages__page1__visuals__d3c0000000000000__visual.json` =
`definition/pages/page1/visuals/d3c0000000000000/visual.json`).

`definition.pbir`'s `semanticmodelid` is sanitized to zeros.

## Features exercised

- PBIR multi-part layout: `definition__report.json`, `pages.json`, per-visual `visual.json`
- 9 visuals on one page (4 KPI cards `d3c...`, 4 charts `d3ch...`, 1 table `d3tb...`)
- Bookmarks (`bookmarks.json` + 3 `.bookmark.json` states — the
  bookmark→per-state-Sigma-workbook migration input)

## Converter

No single MCP tool — consumed by the powerbi-to-sigma skill's PBIR workbook
builder (`build-workbook-from-pbir.rb`); the model layer is the paired `.bim`.
No golden; expectations pin artifact presence/parse.

## Expectations

```json
{
  "artifacts": [
    {"path": "definition.pbir", "format": "json"},
    {"path": "definition__report.json", "format": "json"},
    {"path": "definition__version.json", "format": "json"},
    {"path": "definition__pages__pages.json", "format": "json"},
    {"path": "definition__pages__page1__page.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3c0000000000000__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3c0000000000001__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3c0000000000002__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3c0000000000003__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3ch0000000001__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3ch0000000002__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3ch0000000003__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3ch0000000004__visual.json", "format": "json"},
    {"path": "definition__pages__page1__visuals__d3tb0000000001__visual.json", "format": "json"},
    {"path": "definition__bookmarks__bookmarks.json", "format": "json"},
    {"path": "definition__bookmarks__overview.bookmark.json", "format": "json"},
    {"path": "definition__bookmarks__kpisOnly.bookmark.json", "format": "json"},
    {"path": "definition__bookmarks__trendSpotlight.bookmark.json", "format": "json"}
  ],
  "goldens": {}
}
```
