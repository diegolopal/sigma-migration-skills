# cognos / great-outdoors-module

The "Great Outdoors" (GO Sales-style) Cognos Data Module JSON from the
cognos-to-sigma plugin fixtures (referenced, not duplicated). 22 query
subjects with calculations, regular aggregates, and 14 link relationships —
the richest of the plugin's module fixtures.

## Converter

The **in-repo converter** (not MCP), from the plugin's converter/ dir:

```
cd plugins/cognos-to-sigma/skills/cognos-to-sigma/converter
npm install            # once (tsx + fast-xml-parser)
npm run --silent convert ../fixtures/great-outdoors.module.json > model.json
```

Stats + warnings print to stderr; the golden wraps them with the payload as
`{sigmaDataModel, stats, warnings}` to mirror the MCP converters' shape.
(`convert_cognos_to_sigma` also exists in MCP; the plugin's converter is the
source of truth that gets mirrored there.)

## Features exercised

- querySubjects → table elements; facts w/ regularAggregate → metrics
- Cognos calculation DSL: cast()/Year()/Quarter()/Month()/Date() flag path
  (13 warnings expected — these are the "no confirmed mapping" review flags)
- link[] → 14 relationships (source = many side)

## Known parity reference

The cognos-to-sigma converter line was live-validated to EXACT parity on the
companion sales module/report pair: **$110,342.75 total / 653 orders**.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/great-outdoors.module.json", "format": "json"},
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/telco-churn.module.json", "format": "json"},
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/sample-data-module.module.json", "format": "json"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 25,
      "columns": 114,
      "metrics": 10,
      "relationships": 14,
      "warnings": 13
    }
  }
}
```
