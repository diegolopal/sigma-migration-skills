---
name: looker-to-sigma
description: >-
  Convert a Looker instance (LookML semantic model + dashboards) into a Sigma
  data model and matching workbook(s). Use when the user has Looker content —
  LookML projects, explores, or dashboards (user-defined OR LookML-defined) —
  and wants to recreate it in Sigma. Discovery via the Looker REST API 4.0 /
  Looker MCP server (or LookML files offline), model conversion via the
  convert_lookml_to_sigma converter, dashboard → workbook conversion from the
  Looker Dashboard API JSON, build via the Sigma REST API, and 3-way parity
  verification against the source warehouse — driven by `scripts/*`.
user-invocable: true
---

# Looker → Sigma Conversion

Convert a Looker LookML semantic model into a Sigma data model, then build Sigma
workbook(s) that mirror the Looker dashboards (user-defined OR LookML-defined) as
closely as possible — and verify the numbers match Looker AND the warehouse.

**Read ALL of the following before replying or taking any action. Do not make assumptions about skill conventions, prompts, or global instructions — read the files.**
- `refs/dashboard-contract.md` — the normalized Looker Dashboard JSON contract both the live API fetch and the offline LookML parse produce. The dashboard pipeline is source-agnostic; it only sees this contract.
- `refs/looker-dashboard-layout.md` — the deep desk study: Looker layout modes, newspaper→24-col grid math, tile-type / filter-type maps, and the full translation-hazard catalog (Liquid, `merged_results`, table calcs, view/explore field resolution, cross-filtering). **This is the design backbone of the dashboard pipeline.**

**For canonical spec shape** (data-model element kinds, workbook element kinds, controls, formulas, formatting), defer to the companion **`sigma-data-models`** and **`sigma-workbooks`** skills. This skill restates only the Looker-conversion-specific patterns.

---

## The two artifacts, two pipelines

Looker has two independent layers; convert them separately.

| Layer | Source (production = API-first) | Converter | Sigma output |
|---|---|---|---|
| **Semantic model** | LookML views+model (Looker API/MCP, or files offline) | `mcp__sigma-data-model__convert_lookml_to_sigma` | data model |
| **Dashboards** | `GET /dashboards/{id}` JSON — covers **user-defined (UDD) AND LookML dashboards** | `fetch_looker_dashboard.py` → contract → `build_workbook.py` | workbook |

**Critical — UDD is the primary path.** Most real Looker dashboards are **user-defined
(UDD)** — built in the UI, NOT in any LookML file. They are reachable ONLY via the Looker
API, which returns UDD and LookML dashboards as the **same** `Dashboard` JSON
(`dashboard_elements[]` + `dashboard_layouts[]` + `dashboard_filters[]`). So the dashboard
converter keys off that API JSON, not LookML. `.dashboard.lookml` parsing is a secondary,
offline-only path that normalizes into the same contract.

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/get-token.sh` | Exchange `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` → `SIGMA_API_TOKEN` (~1h TTL). `eval "$(scripts/get-token.sh)"` |
| `scripts/looker_api.py` | Minimal Looker REST API 4.0 client (no SDK). Reads `~/.looker/looker.ini`, logs in via `client_credentials`, exposes `L.call(method, path, body)`. CLI: `python3 looker_api.py whoami` / `get <path>` / `raw GET /lookml_models`. |
| `scripts/fetch_looker_dashboard.py` | **Phase 1 (live):** `GET /dashboards/{id}` → the normalized contract (`refs/dashboard-contract.md`). Works for UDD AND LookML dashboards. Self-contained (reads `~/.looker/looker.ini`). `tileType` is read from `query.vis_config.type` (NOT `element.type`, which is always `"vis"`); `listen` from `result_maker.filterables`; layout from the **active** layout's components. |
| `scripts/parse_lookml_dashboard.py` | **Phase 1 (offline):** parse a `.dashboard.lookml` (YAML) → the SAME contract. Dev/test only; cannot see UDD dashboards. Requires PyYAML. |
| `scripts/detect_rls.py` | **Phase 1 (RLS scan):** dependency-free regex scan of a LookML dir/file (and/or model JSON) for row-level-security constructs (`access_filter`, `sql_always_where`, `access_grant`, `user_attribute`). Prints a structured summary + recommended Sigma mapping per finding (or `--json`). **Prints nothing / exits 0 when there's no RLS** (zero-overhead). `python3 detect_rls.py <lookml_dir> [--json]` |
| `scripts/convert_dm.mjs` | **Phase 2:** run `convertLookMLToSigma` against a directory of `.lkml` files for one explore → a Sigma DM spec JSON. Bypasses the deployed MCP build (see the converter-build gotcha below). Env: `LOOKML_DIR`, `CONVERTER_SRC`; args `<exploreName> <out.json>`. |
| `scripts/post_dm.py` | **Phase 2:** POST a DM spec to `/v2/dataModels/spec` (auto-finds a writable folder, swaps in the full connection UUID). Env: `SIGMA_API_TOKEN`, `SIGMA_BASE_URL`, `SIGMA_CONNECTION_ID`; args `<spec.json>`. |
| `scripts/build_workbook.py` | **Phase 3:** dashboard contract + the explore's view `.lkml` files → a Sigma `/v2/workbooks/spec` body (hidden Data page + master table, one element per tile, controls from filters, newspaper→24-col layout XML). Generates locally; does **not** POST. Handles ratio measures, joined-col `Field (alias)` naming, table calcs, pivot-flatten + warn. |
| `scripts/build_looker_dashboard.py` | **TEST-FIXTURE BUILDER (not a migration step).** Builds the "Orders Overview" UDD on `csa_thelook` via the Looker API (4 KPIs + line/column/bar/pie + grid, 3 filters wired via `result_maker.filterables.listen`). |
| `scripts/build_looker_dashboard2.py` | **TEST-FIXTURE BUILDER (not a migration step).** Builds the "Orders Deep Dive" UDD — area, pivot, table-calcs, scatter, donut, text tile — the harder dashboard surface for the converter. |

> **Test-fixture builders vs migration scripts.** `build_looker_dashboard.py` /
> `build_looker_dashboard2.py` **author** Looker dashboards (migration *targets*); they are
> for standing up known demo content to convert and parity-check. Never run them against a
> customer's Looker. Everything else converts *from* Looker *to* Sigma.

---

## Prerequisites

### Looker credentials (`~/.looker/looker.ini`)

```ini
[Looker]
base_url=https://<your-instance>.cloud.looker.com:19999
client_id=<API3 client_id>
client_secret=<API3 client_secret>
verify_ssl=True
```

- **API 4.0**, key-pair-free `client_credentials` (login on `:19999` returns a bearer).
- The credential's user needs **Admin** (or at least: see models, dashboards, run queries, and
  — for the test-fixture builders or Git-deploy flow — develop + deploy).
- Generate an API3 key in Looker: **Admin → Users → (your user) → Edit Keys → New API3 Key**.
- Test: `python3 scripts/looker_api.py whoami` → prints HTTP 200, your display name + roles.

### Sigma credentials

`eval "$(scripts/get-token.sh)"` exchanges `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` (from
`~/.sigma-migration/env`, written by the `sigma-api` skill's `setup.rb`) for a `SIGMA_API_TOKEN`.
Also note your **full connection UUID** (`SIGMA_CONNECTION_ID`) and a writable **folderId**.

> Tokens live ~1 hour. Re-fetch when a curl returns 401. Never use
> `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` is a subshell where the exported var dies.
> Keep `eval` + `curl` in the same `bash -c '...'` invocation.

> **Inline Python/Node inside bash — DON'T.** Triple-nested escapes silently break. Always
> write a `.py`/`.mjs` file with `Write` and call it via `python3 file.py` / `node file.mjs`.
> The scripts here already follow that rule.

### The Looker-side warehouse connection (one-time, for live parity)

Looker needs its **own** direct warehouse auth — Sigma's connection UUID is Sigma-side and
unusable for Looker. To stand up an end-to-end test pointed at the same warehouse as Sigma
(so 3-way parity is meaningful):

- **Snowflake service identity:** create a `SERVICE`-type user with **key-pair** auth (Snowflake
  blocks single-factor passwords for service users) + a role granting USAGE on the warehouse +
  the db/schema and SELECT on the tables/views.
- **Looker connection** (`POST /connections`): `uses_key_pair_auth: true`, `certificate` =
  base64 of the `.p8` private key, `file_type: ".p8"`, warehouse via
  `jdbc_additional_params=warehouse=<WH>`, host `<account>.snowflakecomputing.com`. Test via
  `PUT /connections/{name}/test`.
- **Git-backed project + model:** create a project in the **dev** workspace, add a deploy key to
  the Git repo, set the git remote via **`PATCH /projects/{id}`** (PUT 404s). All dev-workspace
  mutations need **ONE persistent session** (`PATCH /session {workspace_id: dev}`).

> This setup is only needed to build a *live* test instance. For a customer migration the Looker
> instance + connection already exist — you just read from them.

---

## Phase 0 — Assess the Looker estate

Scope the migration before converting anything — inventory models/explores/dashboards, score
complexity, and rank a migration shortlist. This is handled by the **`looker-assessment`**
sibling skill (analogous to `tableau-assessment` / `qlik-assessment`). Run it first for any
multi-dashboard migration; skip it for a single known dashboard.

---

## Phase 1 — Discover the Looker content

Three transports, in order of preference: **Looker MCP** (when wired in) → **Looker REST API
4.0** (the default here) → **offline `.lkml`** (dev/test, can't see UDDs).

### 1a. Smoke-test + list

```bash
python3 scripts/looker_api.py whoami                 # confirm auth + admin
python3 scripts/looker_api.py raw GET /lookml_models  # list models
python3 scripts/looker_api.py raw GET /dashboards     # list dashboards (UDD + LookML)
```

For a specific explore's field graph:
`python3 scripts/looker_api.py raw GET /lookml_models/<model>/explores/<explore>`.

### 1b. Pull each dashboard into the normalized contract (live)

```bash
python3 scripts/fetch_looker_dashboard.py <dashboard_id> /tmp/<name>/<dash>.contract.json
```

This hits `GET /dashboards/{id}` and normalizes into `refs/dashboard-contract.md`. It works
for UDD **and** LookML dashboards (the API returns both identically). Key extraction details
(already handled by the script):
- **`tileType` comes from `query.vis_config.type`**, not `element.type` (which is always
  `"vis"` for chart tiles, `"text"` for text tiles).
- **`listen`** (which dashboard filters a tile obeys) comes from
  `result_maker.filterables[].listen`.
- **layout** comes from the **active** layout's `dashboard_layout_components[]`
  (`row`/`column`/`width`/`height`); ignore mobile variants.
- **`dynamic_fields`** (table calcs / client-side custom measures) arrives as a **JSON string**
  — the script `json.loads` it.

### 1c. Offline path (dev/test only)

```bash
python3 scripts/parse_lookml_dashboard.py <file.dashboard.lookml> --out /tmp/<name>/<dash>.contract.json
```

Same contract shape. Cannot see UDD dashboards; LookML dashboards may also lag the live UI
state (a `.dashboard.lookml` reflects source-of-truth, the API reflects edits). **Prefer the
API.** Note: a deployed LookML dashboard does NOT auto-index for `import_lookml_dashboard`
(Looker reindexes lazily, 404 until then) — just build/discover the UDD directly.

> **No live instance?** A GCP free-trial account CANNOT provision Looker (instance quota is
> `isFixed` = 0, Sales-gated). Build/test from sample LookML + the offline path. The validated
> end-to-end run used a real `hakkoda1.cloud.looker.com` instance pointed at `CSA.TJ`.

### 1d. Scan for row-level security (RLS) — cheap, silent if none

Looker enforces row-level security in LookML, and **security is the one place a silent default
is dangerous in both directions** — silently dropping RLS exposes data; silently porting a wrong
mapping over- or under-restricts it. So scan for it during discovery, but stay out of the way
when there's nothing to decide.

```bash
python3 scripts/detect_rls.py /path/to/lookml          # the project dir (and/or a model JSON)
```

- **Zero overhead on the happy path.** `detect_rls.py` is a cheap regex scan; **if it finds no
  RLS it prints nothing and exits 0** — no prompt, no extra phase, the migration proceeds
  straight to Phase 2 unchanged.
- **If it finds RLS, it lists every finding** (construct, explore, field, `user_attribute`,
  expression) plus the recommended Sigma mapping — that output feeds the **single** RLS decision
  gate below (do NOT prompt per rule). The constructs it detects, and their Sigma targets:

  | Looker RLS construct | What it does | Sigma target |
  |---|---|---|
  | `access_filter` (explore) | maps a `user_attribute` → a field; restricts rows to the caller's allowed values | a Sigma **user attribute** + a row filter using `LookupUserAttributeText(...)` / `CurrentUserAttributeText(...)` on that field |
  | `sql_always_where` (explore) | a hardcoded SQL row filter always ANDed onto the explore | a Sigma **data-model / element filter** (if the expression references a `user_attribute` / `{{ _user_attributes[...] }}`, make it a user-attribute row filter, not a static one) |
  | `access_grant` (model) | gates explores/fields/joins by a `user_attribute`'s allowed values | **note / review** — no 1:1 analog; map to Sigma **permissions** or a user-attribute filter |
  | `user_attribute` reference | any other `_user_attributes[...]` / `user_attribute:` use | **provision** the matching Sigma user attribute (reuse if it already exists) |

> The `convert_lookml_to_sigma` converter ALSO detects `access_filter` and emits an RLS note (and
> a `CurrentUserAttributeText()` row-filter stub) in the DM spec. `detect_rls.py` is the
> discovery-time, project-wide view that drives the **decision gate** — the converter handles the
> per-spec emission once you've decided to port.

---

## Phase 1.5 — RLS decision gate (only if Phase 1d found RLS) — BEFORE building

**Skip this phase entirely when `detect_rls.py` found nothing.** When it DID find RLS, stop ONCE,
here, before POSTing the data model in Phase 2 — make it one explicit, reviewed decision, never an
invisible default.

1. **Reuse-first — check what already exists in Sigma before creating anything.** The customer may
   have already set RLS up in Sigma; don't duplicate it.
   - **Existing Sigma user attributes** — list them and match by name to the Looker
     `user_attribute`s in the findings. (Manual check today: **Administration → User Attributes**
     in the Sigma UI; reuse a matching attribute rather than creating a new one. If a list
     endpoint becomes available, prefer it — but do not block on it; the manual check is the
     contract.)
   - **Existing data models with similar RLS logic** — if a Sigma DM already filters the same
     field by the same attribute (e.g. a previously-migrated explore on the same source), reuse it
     instead of re-implementing the filter.
2. **Pre-fill a recommended plan.** Using the mapping table above, draft the per-finding Sigma
   action (which user attribute, which field, `LookupUserAttributeText`/`CurrentUserAttributeText`
   filter vs DM/element filter vs note) — reusing the existing Sigma attributes/DMs found in step 1.
3. **One consolidated confirm / edit / skip.** Present the full plan and let the user, in a SINGLE
   decision: **confirm** it as drafted, **edit** any mapping (e.g. point at a different existing
   attribute, change a field), or **skip** porting RLS entirely (they may enforce it elsewhere in
   Sigma). No per-rule nagging.
4. **Always record the outcome.** For every finding, note **ported / reused / skipped** in the
   migration summary (Phase 4 output) so any skipped RLS is **visible, never silent** — a reviewer
   can see exactly which Looker restriction was carried over, reused, or deliberately dropped.

Then proceed to Phase 2. Apply the confirmed plan as part of the DM build: create/reuse the Sigma
user attribute(s), and add the row filter(s) to the data model (or element) — `access_filter` and
user-attribute `sql_always_where` → `LookupUserAttributeText`/`CurrentUserAttributeText` row
filters; static `sql_always_where` → a plain DM/element filter; `access_grant` → the recorded note.

---

## Phase 2 — Convert the LookML semantic model

LookML views + model → Sigma data model. Resolve the explore's join graph, convert, POST,
**register the model**, and verify.

### 2a. Convert with `convert_lookml_to_sigma`

The MCP tool `mcp__sigma-data-model__convert_lookml_to_sigma(files, connectionId, exploreName,
joinStrategy)` is the primary path. Feed it the **LookML model**, NOT the warehouse tables —
the converter walks the explore's `join`s to resolve `view.field` prefixes (alias vs `from:`
view) and emits one element per resolved view plus a denormalized explore element.

> **Converter-build gotcha.** The long-running MCP server serves the **deployed** build. After
> editing `src/lookml.ts` + `npm run build`, the running MCP tool still serves the OLD code
> until it restarts. For fixed output against an edited source tree, run the converter directly:
>
> ```bash
> LOOKML_DIR=/path/to/lookml \
> CONVERTER_SRC=/path/to/sigma-data-model-mcp/src/lookml.ts \
>   node --import tsx/esm scripts/convert_dm.mjs <exploreName> /tmp/<name>/dm-spec.json
> ```
>
> `convert_dm.mjs` reads `<model>.model.lkml` + every `views/*.view.lkml`, converts the explore
> with `joinStrategy: 'relationships'`, and writes `res.model` (the return property is `.model`,
> **not** `.sigmaDataModel`). It prints stats + warnings — **read every warning.**

### 2b. Converter coverage (all live-validated 2026-06-10) — and what's still lossy

The converter handles, end-to-end and clean:
- **Dimensions** — `tier`, sql `CASE`, legacy `case:` (→ nested `If()`), `html`/`link`, custom
  `value_format`.
- **Time + duration `dimension_group`** — one column per timeframe (`DateTrunc`); duration groups
  emit `sql_start`/`sql_end` physical columns.
- **Measures** — `sum`/`count`/`count_distinct`/`avg`/`median`/`percentile`/filtered/**ratio**.
  Measure `${dimension}` refs and measure-references-measure `${measure}` (ratio) refs resolve to
  the right Sigma formula; `1.0` literals preserved; `NULLIF` → `NullIf`.
- **Joins** — snowflake (multi-hop) joins wire the FK to the correct intermediate element (not
  always the base); `full_outer` + field-limited joins; `sql_always_where` / `always_filter`.
- **Other** — `derived_table`, `parameter` + Liquid, `drill_fields`, `set`, view/group labels,
  multiple explores per model.

These 8 converter bugs were found and **FIXED in source** (branch
`tj/lookml-robustness-ratio-percentile-html-fixes`); treat them as **handled**, but know the
shapes so you recognize a regression:

| # | Bug (now fixed) | What it produced before the fix |
|---|---|---|
| BUG1 | measure `${dimension}` refs unresolved | literal `Sum([${sale price}])` + phantom `${...}` columns |
| BUG2 | multi-hop (snowflake) joins mis-wired | FK hung off the base element instead of the intermediate |
| BUG3 | ratio measures (`${measure}`, `1.0`→`0`) | phantom column + `0 * ${...}` formula |
| BUG4 | `html:`/Liquid `%}` desynced the block parser | silently dropped ALL view fields after the html dimension |
| BUG5 | `percentile` → bogus `CountIf` | wrong aggregation |
| BUG6 | filtered `type:count` with no sql | bogus phantom value column |
| BUG7 | `type:duration` dimension_group | dangling `DateDiff` (no sql_start/sql_end) |
| BUG8 | legacy `case:{when/else}` dim | passthrough to a nonexistent column |

> If the running MCP build predates these fixes, use the `convert_dm.mjs` direct path (2a)
> against a patched source tree, OR repair the spec post-hoc — but the source fixes mean **raw
> converter output now POSTs clean with no in-spec workarounds**.

**Still lossy / unsupported (documented, warned — never silent):**
- **Liquid `{% parameter %}` measures** and **manifest constants** — Looker API-deploy cache
  quirk; review.
- **`link:` / `html:` styling** — dropped (data is fine; the styling/hyperlink is lost).
- **Pivot cross-tab** → flattened to columns + warn (rebuild as a Sigma `pivot-table` in the UI).
- **Table-calc grain/sort** for window functions (rank / offset / percentile) → review.
- **`merged_results`** → a DM join or a Custom SQL element (follow `merge_result_id` to the
  source queries; >2 sources or non-equi joins → manual + warn).
- **Not yet converted:** NDT (`explore_source`), PDT `datagroup`/`persist_for`, `many_to_many`.
- **RLS (`access_filter` / `sql_always_where` / `access_grant`)** — detected at discovery
  (Phase 1d) and decided ONCE at the Phase 1.5 gate; the converter emits an `access_filter` RLS
  note + `CurrentUserAttributeText()` stub. Never silently dropped — the outcome is recorded.

> **`metric()` returns "Missing Metric" in MCP SQL** — a known Sigma quirk, not a conversion
> bug. Verify metric values via the **raw aggregate** (`Sum(...)`, `CountDistinct(...)`), not via
> `metric()`.

### 2c. POST the data model

```bash
bash -c 'eval "$(scripts/get-token.sh)" && \
  SIGMA_CONNECTION_ID=<full-connection-uuid> \
  python3 scripts/post_dm.py /tmp/<name>/dm-spec.json'
```

- Endpoint is `POST /v2/dataModels/spec` (NOT `/v2/workbooks/spec`).
- **Use the FULL connection UUID** (e.g. `bc0319f8-9fe0-4315-aea3-6a2d1eef0623`), not a short
  prefix — `convert_dm.mjs` writes a placeholder `connectionId`; `post_dm.py` swaps in
  `$SIGMA_CONNECTION_ID`.
- **`folderId` is required** — `post_dm.py` auto-picks a writable folder (preferring one whose
  name mentions LOOKER/MIGRATION/TEST).
- **The spec endpoints return YAML** (`success: true\nworkbookId: …`), not JSON — never
  `json.load` the response or pipe it to `jq`.

Record the returned `dataModelId` and (after a read-back) the element IDs.

### 2d. Register the model + verify

> A freshly POSTed/deployed LookML model **404s on query until you register it** (Looker side
> for the Looker model; this is the deploy flow for standing up a test instance):
>
> ```
> PATCH /session {workspace_id: dev}
> PUT  /projects/{id}/git_branch {name: <dev-branch>, ref: origin/main}   # pull pushed commits into dev
> POST /projects/{id}/validate                                            # expect 0 errors
> POST /projects/{id}/deploy_to_production                                # 204
> POST /lookml_models {name, project_name, allowed_db_connection_names:[<conn>]}
> ```
>
> LookML param gotcha: params are **not** semicolon-separated — compact
> `{ primary_key: yes; hidden: yes; sql: ... ;; }` fails ("Invalid lookml syntax") and cascades
> into bogus join/field errors. Use multi-line blocks (only `;;` terminates a `sql`).
> A refinement `view: +x` in a glob-included file fails ("Could not find a view to extend") —
> fold the param/measure into the base view.

**Verify the Sigma DM:** `mcp__sigma-mcp-v2__describe` the element (no `type=error` columns;
metric formulas resolve clean), then `mcp__sigma-mcp-v2__query` a raw aggregate and confirm it
matches the warehouse.

---

## Phase 3 — Convert the dashboards (UDD = primary)

For each Looker dashboard, fetch its contract (Phase 1b), then build a Sigma workbook spec.

### 3a. Build the workbook spec

```bash
python3 scripts/build_workbook.py /tmp/<name>/<dash>.contract.json \
  --views /path/to/lookml/views \
  --dm-id <dataModelId> \
  --element-id <denorm-element-id> \
  --dm-element-name "<DM element display name>" \
  --folder-id <writable-folder-id> \
  --out /tmp/<name>/<dash>.workbook.json
```

(`contract` is positional. `--dm-element-name` is the display name of the data-model element
the master table pulls from; `--master-name` defaults to `Data`. The generated spec has
placeholder defaults for any flag you omit, so it always generates locally — fill in the real
ids before POSTing.)

`build_workbook.py` consumes the contract + the explore's view `.lkml` files (to classify each
`view.field` as a measure — agg + base col — or a dimension, and derive the Sigma formula) and
emits a `/v2/workbooks/spec` body:
- a **hidden "Data" page** with a master table sourced from the DM element,
- a **dashboard page** with one element per Looker tile,
- **controls** from the dashboard filters,
- a **newspaper → 24-col grid layout** XML string.

Tile-type, filter-type, and layout maps are in `refs/dashboard-contract.md` and
`refs/looker-dashboard-layout.md` — **do not duplicate them; defer there.** Summary:

| Looker tile `type:` | Sigma kind |
|---|---|
| `single_value` | `kpi-chart` |
| `looker_column` / `looker_bar` | `bar-chart` |
| `looker_line` | `line-chart` |
| `looker_area` | `area-chart` |
| `looker_pie` | `pie-chart` |
| `looker_donut_multiples` | `donut-chart` (single ring) + warn |
| `looker_scatter` | `scatter-chart` |
| `looker_grid` / `table` | `table` |
| `text` | `text` (markdown body) |
| `looker_map` / geo / funnel / waterfall / boxplot / sankey / custom viz | none — approximate or drop + warn |

Newspaper layout math (a single arithmetic transform, no spatial heuristic):
`gridColumn = (col+1) / (col+1+width)`, `gridRow = (row+1) / (row+1+height)`. `tile` / `static`
/ `grid` modes need a snap heuristic (lossy) — warn + stack; see `refs/looker-dashboard-layout.md` §3.

### 3b. Workbook-spec gotchas (learned the hard way)

- **`/v2/workbooks/spec` returns YAML** — don't `json.load` the response.
- **control elements** live in `page.elements[]` with `kind: control` but REQUIRE an `id`
  (separate from `controlId`); a missing `id` → `Invalid kind: "control"`.
- **KPI `value` uses `value.columnId`** on the live API (the `sigma-workbooks`
  `example-full.yaml` shows `value.id` — the API wants `columnId`). **BUT donut/pie `value`
  uses `value.id`** (not columnId) — the two element types genuinely differ; verified by POST
  400s both ways.
- **Chart `color` channel differs by type:** bar/area/line series = `{by: "category", column:
  <id>}`; donut/pie slice = `{id: <id>, sort?}`. (A Looker pivot maps to this color channel.)
- **donut/pie use `value` + `color`, NOT `xAxis`/`yAxis`.**
- **KPI comparison (`show_comparison`) has NO spec slot** — warn, don't build. (Recommend a 2nd
  KPI tile or a UI delta post-publish.) Looker `donut_multiples` per-multiple dim is also dropped → warned.
- **Master → DM-element refs:** a master table sourcing a DM element references columns as
  `[<DM-element-NAME>/<col display>]`; tiles then reference `[<master-NAME>/<col display>]`.
- **Joined-view columns** in the denorm DM element are named `<Field> (<joinAlias>)` (Sigma
  disambiguates cross-element lookup cols) — master/tile refs must include the suffix, e.g.
  `[Order Fact/Region (customer_dim)]`.
- **Table calcs** → workbook formula columns: `running_total` → `CumulativeSum`,
  `pct_of_total`/`sum()` → `GrandTotal`, `offset(…,-1)` → `Lag`. (`build_workbook.py` translates
  these; `dynamic_fields` arrives JSON-parsed from discovery.)
- **count on a joined view** → `CountDistinct` using that view's primary key (base-view counts
  stay `Count()`).

### 3c. POST the workbook + verify

POST the spec to `/v2/workbooks/spec` (returns YAML → record the `workbookId`). Then
`mcp__sigma-mcp-v2__describe` each element (no `type=error` columns) and confirm the layout
applied. **POST is create-only** — every subsequent spec edit MUST use `PUT
/v2/workbooks/{id}/spec`; re-POSTing leaves orphan workbooks in My Documents (delete via `DELETE
/v2/files/{id}`).

---

## Phase 4 — Verify parity (3-way: Looker vs Sigma vs warehouse) — MANDATORY

A conversion is not complete until the numbers tie out. Compare at **two grains**: the model's
key metrics, and per-tile.

1. **Looker** — `POST /queries/run/json` (or `run_inline_query`) for the model/explore, e.g.
   net revenue by region.
2. **Sigma** — `mcp__sigma-mcp-v2__query` against the DM element (raw aggregate, since
   `metric()` returns "Missing Metric") AND against each workbook chart element.
3. **Warehouse** — the source-of-truth `SELECT` (via the Sigma connection or `snow`).

GREEN only when all three match. The validated run produced **exact** parity to the cent —
region revenue (West 38906.82 / South 31650.98 / NE 21587.52 / MW 14966.20 / null 3231.23 =
$109,765.89) and the ratio metrics (AOV / margin / return) identical across Looker and Sigma.

**Record the RLS outcome here.** If Phase 1d found RLS, the migration summary MUST list, per
finding, whether it was **ported / reused / skipped** (and the Sigma user attribute + filter used)
— so any skipped Looker restriction is visible to a reviewer, never silently dropped. (When RLS
is active, parity-check as a representative restricted user, not only as an admin who sees all
rows.)

> **If `mcp__sigma-mcp-v2__query` errors with an auth message mid-Phase-4**, the MCP session
> staled — re-call `mcp__sigma-mcp-v2__begin_session` and retry. Do not skip parity over a
> recoverable auth error.

---

## Phase 5 — Enhance (post-publish, UI-only features)

Some Looker features have no spec-API analog and must be wired in the Sigma UI after publish.
Set expectations up front (they appear as warnings from `build_workbook.py`):

- **Cross-filtering** (clicking a Looker bar filters siblings) → Sigma "Set as filter" actions —
  UI-only.
- **Trellis / small multiples** (incl. `looker_donut_multiples`) → Sigma trellis — UI-only; the
  spec API silently drops trellis fields.
- **Tooltips / `note_text` / `subtitle_text`** → no spec slot; concatenate into the chart title
  or add an adjacent `text` element.
- **KPI comparison** (`show_comparison`) → add a 2nd KPI tile or a UI delta.
- **Pivot cross-tab** → rebuild the flattened table as a Sigma `pivot-table` in the UI.
- **Per-tile refresh intervals** → Sigma has workbook-level scheduled refresh only — drop + warn.

---

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `convert_dm.mjs` output still has the old bug shape | Edited `src/lookml.ts` but the MCP server serves the deployed build | Run `convert_dm.mjs` via `node --import tsx/esm` against the patched `src/` (or restart the MCP server) |
| Converter dropped all view fields after an `html:` dim | Stale build predating BUG4 fix | Use the patched source path; the `;;`-block pre-extraction now includes `html`/`sql_on`/etc. |
| Metric formula contains `${...}` literals or `0 *` | Stale build predating BUG1/BUG3 fixes | Patched source resolves `${dim}`/`${measure}` refs and preserves `1.0` |
| `metric()` returns "Missing Metric" in a Sigma query | Known Sigma quirk | Verify via raw aggregate (`Sum`/`CountDistinct`), not `metric()` |
| `Source not found: warehouse table …` on DM POST | Short connectionId, or table not in Sigma's static catalog | Use the FULL connection UUID; if still failing, source via a Custom SQL DM element (`kind: "sql"`) |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML | Never pipe spec responses to `jq` / `json.load` |
| `Invalid kind: "control"` on workbook POST | Control element missing its own `id` (separate from `controlId`) | Add a distinct `id` |
| KPI POSTs 400 with `value.id` / donut POSTs 400 with `value.columnId` | The two element types use different value keys | KPI → `value.columnId`; donut/pie → `value.id` |
| Tile shows the wrong chart kind | Read `element.type` (always `"vis"`) instead of `query.vis_config.type` | `fetch_looker_dashboard.py` already reads `vis_config.type` — re-fetch the contract |
| Looker LookML deploy fails "Invalid lookml syntax" | Compact `{ a: yes; b: yes; }` params | Use multi-line blocks; only `;;` terminates a `sql` |
| LookML model 404s on query right after deploy | Model not registered | `POST /lookml_models {name, project_name, allowed_db_connection_names}` |
| `PUT /projects/{id}` 404 when setting git remote | Wrong verb | Use `PATCH /projects/{id}` |
| Looker dev-workspace mutation has no effect | Each `looker_api.py` call logs in fresh (new session) | For multi-step dev flows use ONE persistent session (`PATCH /session {workspace_id: dev}` then reuse the bearer) |
