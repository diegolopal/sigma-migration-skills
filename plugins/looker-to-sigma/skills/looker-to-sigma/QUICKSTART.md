# Looker → Sigma — Quickstart

End-to-end: a Looker LookML model + its dashboards (UDD or LookML-defined) → a Sigma data model
+ workbook(s), parity-verified against Looker AND the warehouse.

## 1. Authenticate

**Looker** (REST API 4.0). Put an API3 key in `~/.looker/looker.ini`:
```ini
[Looker]
base_url=https://<your-instance>.cloud.looker.com:19999
client_id=<API3 client_id>
client_secret=<API3 client_secret>
verify_ssl=True
```
Generate the key in Looker: **Admin → Users → (you) → Edit Keys → New API3 Key**. Test it:
```bash
python3 scripts/looker_api.py whoami        # HTTP 200 + your name/roles
```

**Sigma**: credentials via the `sigma-api` skill (`ruby scripts/setup.rb` once → `~/.sigma-migration/env`).
```bash
eval "$(scripts/get-token.sh)"              # sets SIGMA_API_TOKEN (~1h TTL)
export SIGMA_CONNECTION_ID=<full-connection-uuid>   # NOT a short prefix
```

## 2. Discover

```bash
python3 scripts/looker_api.py raw GET /lookml_models   # list models/explores
python3 scripts/looker_api.py raw GET /dashboards      # list dashboards (UDD + LookML)

# pull one dashboard into the normalized contract (works for UDD AND LookML)
python3 scripts/fetch_looker_dashboard.py <dashboard_id> /tmp/look/<dash>.contract.json
# offline (dev/test only — cannot see UDDs):
python3 scripts/parse_lookml_dashboard.py <file.dashboard.lookml> --out /tmp/look/<dash>.contract.json

# scan for row-level security (silent + exit 0 if none; if found → ONE decision gate before Phase 3)
python3 scripts/detect_rls.py /path/to/lookml
```

If `detect_rls.py` reports RLS (`access_filter` / `sql_always_where` / `access_grant`), stop ONCE
before building: reuse any existing Sigma user attribute / DM, pre-fill the recommended mapping
(`access_filter` → user-attribute row filter via `LookupUserAttributeText`/`CurrentUserAttributeText`;
`sql_always_where` → DM/element filter; `access_grant` → note), then confirm/edit/skip in a single
decision — and record ported/reused/skipped in the summary (never silently drop RLS).

## 3. Convert the semantic model

Feed the LookML **model** (not the warehouse tables) to the **`convert_lookml_to_sigma`** MCP
tool — it resolves the explore's join graph. For fixed output against a patched converter
source tree (the MCP server serves the *deployed* build), run it directly:
```bash
LOOKML_DIR=/path/to/lookml \
CONVERTER_SRC=/path/to/sigma-data-model-mcp/src/lookml.ts \
  node --import tsx/esm scripts/convert_dm.mjs <explore> /tmp/look/dm-spec.json
```
Read the printed warnings. Then POST + register:
```bash
bash -c 'eval "$(scripts/get-token.sh)" && \
  SIGMA_CONNECTION_ID=$SIGMA_CONNECTION_ID python3 scripts/post_dm.py /tmp/look/dm-spec.json'
```
This POSTs to `/v2/dataModels/spec` (auto-finds a folder, swaps in the full connection UUID).
Verify with `mcp__sigma-mcp-v2__describe` (no `type=error` columns) + a raw-aggregate `query`.

## 4. Convert the dashboards (model → DM → its dashboards → layout)

```bash
python3 scripts/build_workbook.py /tmp/look/<dash>.contract.json \
  --views /path/to/lookml/views \
  --dm-id <dataModelId> --element-id <denorm-element-id> \
  --dm-element-name "<DM element display name>" \
  --folder-id <writable-folder-id> \
  --out /tmp/look/<dash>.workbook.json
```
Emits a `/v2/workbooks/spec` body: hidden Data page + master table, one element per tile,
controls from filters, newspaper→24-col layout XML. POST it to `/v2/workbooks/spec` (returns
YAML → record `workbookId`). **POST once; PUT every later edit** (re-POST leaves orphans).

## 5. Verify parity (3-way) — MANDATORY

Compare at the metric grain and per tile:
- **Looker** — `POST /queries/run/json` for the explore.
- **Sigma** — `mcp__sigma-mcp-v2__query` (raw aggregate; `metric()` returns "Missing Metric").
- **Warehouse** — the source-of-truth `SELECT`.

GREEN only when all three match (the validated run tied out to the cent).

---

### Notes / gotchas

- **UDD is the primary path** — `GET /dashboards/{id}` returns user-defined and LookML dashboards
  identically; the converter is source-agnostic via the contract.
- **Spec endpoints return YAML** — never `json.load` / `jq` the response.
- **KPI `value.columnId`** vs **donut/pie `value.id`**; **control elements need their own `id`**.
- **Lossy + warned:** Liquid `{% %}` measures, manifest constants, `link:`/`html:` styling, pivot
  cross-tab (flattened → rebuild as Sigma pivot-table in UI), table-calc window grain, cross-
  filtering / trellis / tooltips (Sigma UI-only). Wire these in Phase 5 post-publish.
- **`build_looker_dashboard.py` / `build_looker_dashboard2.py` are test-fixture builders** — they
  author Looker dashboards (migration targets), not part of a customer migration.
