# ThoughtSpot → Sigma — Quickstart

End-to-end: a ThoughtSpot model + its Liveboards → a Sigma data model + workbooks,
parity-verified against the warehouse.

## 1. Authenticate
**ThoughtSpot** (REST v2). On an SSO trial with no local password, open
`https://<your>.thoughtspot.cloud/api/rest/2.0/auth/session/token` in the tab where
you're logged in and copy the `token` (or use Develop → REST Playground). For a
repeatable service identity, enable Trusted Auth (Develop → Customizations →
Security Settings) and POST `username`+`secret_key` to `auth/token/full`.
```bash
export TS_HOST="https://<your>.thoughtspot.cloud"  TS_TOKEN="<bearer>"
```
**Sigma**: `export SIGMA_BASE_URL=... SIGMA_API_TOKEN=$(scripts/get-token.sh ...)`
plus `SIGMA_CONNECTION_ID` (the warehouse connection) and `SIGMA_FOLDER_ID`.
Also set `TS_DB` / `TS_SCHEMA` (the warehouse db/schema the model's tables live in).

## 2. Discover
```bash
python3 scripts/ts_discover.py                 # list models + Liveboards
python3 scripts/ts_discover.py <MODEL_ID> LOGICAL_TABLE   # summarize a model
python3 scripts/ts_discover.py <LIVEBOARD_ID> LIVEBOARD   # viz chart types + lineage
```

## 3. Convert the model
Feed the model's TML to the **`convert_thoughtspot_to_sigma`** MCP tool (or point
`CONVERTER_PATH` at a `sigma-data-model-mcp` build for the one-shot path). With
neither, `migrate.py` writes `<workdir>/convert-request.json` (the exact MCP
arguments) and exits 3 — call the tool, save its JSON output, and re-run with
`--converted <file>`. The converter emits a Sigma data model with a denormalized
**"<root> View"** element that surfaces joined-dim columns — the workbook master
reads from it. Rules: `refs/model-conversion-rules.md`.

Before POSTing, run the **DM-reuse check** (SKILL.md step 2.5): `ts-dm-signature.py`
+ `find-or-pick-dm.rb --auto-pick` score the org's existing data models against the
model's tables/columns — on a strong match the skill asks reuse-vs-new and the POST
is skipped.

## 4. Migrate (model → DM → its Liveboards → layout)
```bash
python3 scripts/migrate.py --model <TS_MODEL_ID> --workdir /tmp/ts-run   # all Liveboards on the model
python3 scripts/migrate.py --model <ID> --liveboard <LB_ID> --workdir /tmp/ts-run  # just one
# offline (no TS access): --model-tml fixtures/retail-analytics-model.tml \
#                         --liveboard-tml fixtures/retail-analytics-liveboard.tml
```
This converts + POSTs the DM, discovers the denorm element, derives the column
resolver from the model TML, rebuilds each Liveboard's visualizations as Sigma
elements (KPI/bar/line/pie/pivot/table + search-query filters + sorts), and maps
the Liveboard's own `layout.tiles` geometry onto Sigma's grid. Workbooks/pages
take the Liveboard's display name (`--name` adds a prefix to the DM + workbooks).
Output ids → `<workdir>/migrate_out.json`.

## 5. Verify parity (hard gate)
```bash
ruby scripts/phase6-parity-thoughtspot.rb --workdir /tmp/ts-run --workbook-id <wb>  # PASS 1: plan
# … fetch ACTUAL (mcp__sigma-mcp-v2__query) + EXPECTED (ts_lib.searchdata / warehouse) …
ruby scripts/phase6-parity-thoughtspot.rb --workdir /tmp/ts-run --finalize          # PASS 2: sentinel
ruby scripts/assert-phase6-ran.rb --workdir /tmp/ts-run --workbook-id <wb>          # must exit 0
```
Re-apply layout last if you edit a workbook spec (a bare PUT wipes `spec.layout`).
Workbook RENAMES go through `PATCH /v2/files/{id}` — `PATCH /v2/workbooks/{id}`
silently no-ops.

## Assess first (optional)
`thoughtspot-assessment/scripts/scan.py` inventories the instance, ranks a
migration shortlist (value/cost from `TS: BI Server` usage), and reports
chart-type coverage. `render_html.py` writes a shareable HTML readout.
