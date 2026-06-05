---
name: thoughtspot-to-sigma
description: Convert a ThoughtSpot model/worksheet and its Liveboards into a Sigma data model and matching dashboards. Use when the user has a ThoughtSpot instance (or exported TML) and wants to recreate it in Sigma. Covers discovery (TML export), data-model conversion, workbook build, layout, and parity verification driven by scripts/.
---

# ThoughtSpot → Sigma migration

Recreate a ThoughtSpot **model/worksheet** as a Sigma **data model**, and its
**Liveboards** as Sigma **workbooks**, with parity verified against the live
warehouse.

## Auth
ThoughtSpot REST v2 needs `TS_HOST` + `TS_TOKEN`. On an SSO trial with no local
password, open `${TS_HOST}/api/rest/2.0/auth/session/token` in the logged-in
browser tab (or Develop → REST Playground) and copy the `token`. For a service
identity, enable Trusted Auth (Develop → Customizations → Security Settings) and
POST `username`+`secret_key` to `auth/token/full`. Sigma side uses
`SIGMA_BASE_URL` + `SIGMA_API_TOKEN` (vendored `scripts/get-token.sh`).
Trials often sit behind corp TLS — the Python helpers use an unverified SSL
context (curl uses the system store and works).

## One-shot
```
export TS_HOST TS_TOKEN SIGMA_BASE_URL SIGMA_API_TOKEN \
       SIGMA_CONNECTION_ID SIGMA_FOLDER_ID TS_DB TS_SCHEMA
python3 scripts/migrate.py --model <TS_MODEL_ID> [--liveboard <ID> ...] [--name PREFIX]
```
`migrate.py` runs the whole pipeline with **no hardcoded ids** and migrates every
Liveboard that reads the model (or just the `--liveboard` ones).

## Pipeline (what migrate.py does)
1. **Discover** — `ts_discover.py [<id> <type>]` lists models + Liveboards or
   summarizes one (chart types, search queries, lineage). `metadata/search` +
   `metadata/tml/export`.
2. **Convert the model** — export the model TML and run it through
   `convert_thoughtspot_to_sigma` (`convert_model.mjs` imports the built converter;
   the browser tool / MCP also work). ThoughtSpot exports the **`model:`** format
   (joins inline on `model_tables[].joins[]`, `[TABLE::COL]` formula refs,
   `col.properties.column_type`) — the converter handles it. POST to
   `/v2/dataModels/spec`; then read the posted DM spec to find the denormalized
   **"<root> View"** element (surfaces joined-dim columns via `[base/REL/Field]`).
3. **Resolve columns** — `ts_common.build_resolver(model_root)` derives the
   ThoughtSpot-column → Sigma-denorm-column map **from the model TML itself**
   (replicates the converter's `sigmaDisplayName`; joined dims get a `(TABLE)`
   suffix, fact columns don't). No hardcoded registry → works for any model.
4. **Build workbooks** — per Liveboard, map each visualization
   (`answer.search_query` + `chart.type`) to a Sigma element off the master table.
   Chart map: KPI→kpi-chart, COLUMN/BAR→bar-chart, LINE→line-chart, TABLE→grouped
   table (PIE currently → bar). KPI value uses `{"columnId": c}`; grouped tables
   need `groupings:[{groupBy, calculations}]`.
5. **Layout** — `apply_layouts.py` applies a clean grid (KPIs top row, charts
   2-wide) as the **LAST** write (a bare spec PUT wipes layout).
6. **Parity** — query the model via `ts_lib.searchdata` (ground truth) vs the
   Sigma workbook elements (v2 query MCP); values match to the cent.

## Scripts
- `migrate.py` — **canonical entry**: model → DM → migrate its Liveboards (parameterized)
- `convert_model.mjs` — model TML → Sigma DM spec (imports the built converter)
- `ts_lib.py` — ThoughtSpot REST v2 (whoami/search/export_tml/import_tml/searchdata)
- `ts_discover.py` — inventory / per-object summary
- `ts_common.py` — `build_resolver` (from model TML) + viz↔element mappers
- `dashboards.py` — themed dashboard specs (fixtures)
- `run_migrations.py` — fixture batch: create themed Liveboards + migrate + ground truth
- `apply_layouts.py` — grid layout pass
- `get-token.sh` — Sigma token (vendored)

## Worked example
The CSA.TJ retail star (ORDER_FACT + 5 dims) → ThoughtSpot model "Retail Analytics"
→ converted Sigma DM (6-table star + Order Fact View) → 11 themed Liveboards
migrated to 11 Sigma workbooks, parity exact (Net Revenue 108,797.85; by-category,
region, quarter all match to the cent). See `~/thoughtspot-migration/migration_manifest.json`.

## Notes
- `convert_thoughtspot_to_sigma` is the converter (MCP github.com/twells89/sigma-data-model-mcp
  + browser sigma-data-model-manager) — keep both in lockstep.
- TML export embeds raw control chars in JSON → parse with `json.loads(..., strict=False)`.
- System/sample objects are FORBIDDEN to export (only own content).
