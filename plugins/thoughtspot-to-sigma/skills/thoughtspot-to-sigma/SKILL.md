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
   Chart map: KPI→kpi-chart, COLUMN/BAR/STACKED→bar-chart, LINE→line-chart, PIE/DONUT→
   **donut-chart** (ThoughtSpot renders pies as donuts), PIVOT_TABLE→pivot-table,
   TABLE→grouped table, AREA→area-chart, SCATTER/BUBBLE→scatter-chart (x/y measures
   + optional category color), LINE_COLUMN→combo-chart (first measure bars, rest
   line), GEO_AREA/GEO_BUBBLE→**region-map** (regionType inferred from the geo field
   name; Sigma auto-colors from the measure). No native Sigma kind for funnel /
   waterfall / treemap / heat-map / sankey → those fall back to bar-chart (flagged
   in the assessment). All chart kinds verified live (POST→readback) 2026-06-07.
   Search-query filters (`[Col]='v'`) → element list-filters.
   Aggregate formulas (`sum(x)/sum(y)`, `sqrt(sum())`) become DM **metrics**; column
   formats come from the TML `format_pattern`/`currency_type`. KPI value uses
   `{"columnId": c}`; donut `value`/`color` use `{"id": c}`; grouped tables need
   `groupings:[{groupBy, calculations}]`.
5. **Layout** — `apply_layouts.py` applies a clean grid (KPIs top row, charts
   2-wide) as the **LAST** write (a bare spec PUT wipes layout).
6. **Parity** — query the model via `ts_lib.searchdata` (ground truth) vs the
   Sigma workbook elements (v2 query MCP); values match to the cent.

## Step 2.5 — Reuse an existing DM? (between convert and POST — mirrors tableau Phase 1.5 / powerbi Phase 3.5)

Before step 2 POSTs a NEW data model, check whether an existing Sigma DM already covers
the same warehouse tables (don't add a 4th near-identical DM for the same star):

```bash
python3 scripts/ts-dm-signature.py --tml model.tml \
  --database $TS_DB --schema $TS_SCHEMA --out dm-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature dm-signature.json \
  --out dm-match.json --auto-pick           # exit 0 = candidate ≥ min-score
```

`ts-dm-signature.py` derives `{warehouse_tables, referenced_columns, measures}` from the
exported model TML (`model_tables[].fqn` is a TS guid, so pass the same `TS_DB`/`TS_SCHEMA`
you export for `migrate.py`). Decision:
- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, matched cols
  (N/M), and the inherited-extras warning from `dm-match.json`. If they reuse, run a
  **shape preflight** first — read the candidate DM's spec back and confirm every column the
  Liveboards reference resolves on the element you'll wire to (no `type=error` columns;
  the denormalized "<root> View" element vs separate dims) — then skip the DM POST and
  build the workbooks (step 4) against the matched `recommended_dm_id` + its element ids.
  With `--auto-pick` a clear winner (no tie within 0.05) skips the prompt — still WARN
  about inherited columns/RLS/metrics.
- **Score < 0.6** → POST new and TELL the user no reusable DM was found.

## Scripts
- `migrate.py` — **canonical entry**: model → DM → migrate its Liveboards (parameterized)
- `convert_model.mjs` — model TML → Sigma DM spec (imports the built converter)
- `ts-dm-signature.py` — step 2.5: model TML → DM-reuse signature for `find-or-pick-dm.rb`
- `find-or-pick-dm.rb` — step 2.5: scan existing Sigma DMs, recommend reuse (0.7·column +
  0.2·table + 0.1·metric overlap; `--auto-pick` w/ tie-window). Shared vendor-neutral copy
  (canonical: tableau-to-sigma; needs `scripts/lib/sigma_rest.rb`). Non-destructive.
- `ts_lib.py` — ThoughtSpot REST v2 (whoami/search/export_tml/import_tml/searchdata)
- `ts_discover.py` — inventory / per-object summary
- `ts_common.py` — `build_resolver` (from model TML), viz↔element mappers, format/currency mapping
- `apply_layouts.py` — grid layout pass (run last)
- `compare.py` — visual + structural compare (TS viz PNG vs Sigma element PNG → HTML)
- `ts_screenshot.py` — per-viz PNG export from ThoughtSpot (report/liveboard)
- `gap-scout.md` + `scout-validate.py` + `learned-rules.py` — formula gap-scout (validate + persist unhandled-TML translations)
- `get-token.sh` — Sigma token; `get-ts-token.sh` — ThoughtSpot Trusted-Auth service token

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


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_thoughtspot_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for ThoughtSpot:** `rls_rules` on tables (`ts_username` to `CurrentUserEmail()`, `ts_groups` to `CurrentUserInTeam`), multiple rules OR-combined.

**Flow (only runs when `result.security` is non-empty — zero overhead otherwise):**
1. **Convert + post** the data model as usual. Capture the `dataModelId` and the converter's `result.security[]` (write it to `security.json`).
2. **Gate (opt-in/out, default _Port_).** Show a plain-English summary of each detected rule + recommended Sigma mapping, then ask: **Port** (recommended) / **Customize** (review per-rule attribute/team mapping + username-to-email reconciliation) / **Skip** (migrated model shows ALL rows to everyone). Reuse-first: existing Sigma user attributes/teams are matched before creating new ones.
3. **Provision + apply** with the shared engine:
   ```bash
   eval "$(scripts/get-token.sh)"
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId>            # plan only (default)
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId> --provision --apply
   ```
   `--provision` creates missing user attributes / teams; `--apply` PATCHes the boolean RLS calc column + fail-closed `filters` entry and the `columnSecurities` (CLS) onto the matching element.
4. **Assign membership.** Assign per-user attribute values / team membership from the source tool's group/role membership (the converter reports the attribute/team names; the values come from the source's user mapping).

**Skip is loud:** opting out leaves the migrated model with NO RLS — all rows visible to everyone. Confirm before skipping.

