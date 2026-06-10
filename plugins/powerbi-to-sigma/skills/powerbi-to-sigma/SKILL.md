---
name: powerbi-to-sigma
description: Convert a Power BI report + semantic model into a Sigma data model and matching dashboard. Use when the user has a Power BI report (in Power BI Service / Fabric, or a .pbix/.pbit file) and wants to recreate it in Sigma. Covers connecting to Power BI with no Entra app, extracting the model (TMSL) + report layout (PBIR/Report-Layout), converting via the sigma-data-model MCP, posting the data model + workbook via REST, and parity verification. Can also author dashboards back INTO Power BI via the Fabric write API.
user-invocable: true
---

# Power BI → Sigma

> Status: **foundation** (validated end-to-end 2026-05-31 on the "Employee Dashboard" workforce report).
> Beads: build = `beads-sigma-cs2`; converter gaps = `j89` (M-Snowflake path), `tkd` (element names / schemaVersion / folderId).
> Defers to: `sigma-workbooks` (canonical workbook spec), `sigma-data-models` (DM spec), the `convert_powerbi_to_sigma` MCP tool, and `tableau-to-sigma/scripts/*` (reused verbatim for posting + layout + parity).

## What's proven (the happy path, validated once)
```
1. CONNECT   device-code login, well-known PowerBI-Desktop client, NO Entra app   → scripts/fabric-extract.py
2. EXTRACT   Fabric getDefinition?format=TMSL → model.bim   (+ .pbix Report/Layout for visuals)
3. CONVERT   convert_powerbi_to_sigma MCP (model.bim + connectionId + db/schema) → Sigma DM JSON
4. POST DM   fix spec (schemaVersion + folderId/ownerId + element names) → POST /v2/dataModels/spec
5. WORKBOOK  Data page (master tables per DM element) + chart elements → POST /v2/workbooks/spec
6. LAYOUT    PBIX/PBIR visual x,y,w,h → 24-col grid XML → put-layout.rb
7. VERIFY    sigma-mcp-v2 query each element returns real rows; Phase 6 = compare vs PBI executeQueries (DAX)
```

## Phase 1 — Connect (no Entra app required)
The corporate tenant blocks Entra app creation, Git integration, and XMLA (PPU). The working path:
- `scripts/fabric-extract.py` — device-code via well-known public client **`ea0616ba-638b-4df5-95b9-636659ae5121`** (Power BI Desktop), scope `https://api.fabric.microsoft.com/.default`. User signs in once at the device URL; token cached.
- **`truststore.inject_into_ssl()` is mandatory** (first line) — corp TLS inspection on `api.fabric.microsoft.com`; uses macOS keychain CA.
- See `refs/connection.md` for the full recipe + surprises (works on My-workspace, device-code not CA-blocked).

## Phase 2 — Extract
- **Model**: `getDefinition?format=TMSL` (202 LRO → poll `Location`) → base64 `model.bim` part = the TMSL/TOM JSON the MCP eats. Works even on My-workspace.
- **Layout**: a `.pbix` is a zip; `Report/Layout` is **UTF-16LE** JSON with per-visual `x,y,w,h` (canvas px, 1280×720 default). The model in a `.pbix` is a *binary* `DataModel` blob — NOT usable; get the model via getDefinition or a `.pbit`'s `DataModelSchema`.
- See `refs/powerbi-visual-layout.md` for the Report/Layout & PBIR parsers and the visualType→Sigma-kind table.

## Phase 3 — Convert (MCP)
`convert_powerbi_to_sigma(model_json, connection_id, database, schema)`.
- DAX measures → Sigma metrics. ~70% mechanical; see `refs/dax-to-sigma-coverage.md` and `fixtures/MANIFEST.md` (test oracle: 94 DAX expressions bucketed a/b/c).
- **Known gap `j89`**: the Snowflake `Snowflake.Databases(...) + Navigation` M pattern isn't parsed → pass `database`/`schema` explicitly until fixed.
- **DAX gaps → gap-scout**: for measures the converter buckets `b` (restructure) or `c` (no-equivalent) — `RANKX`, `ALLEXCEPT`, `SUMMARIZE`, `USERELATIONSHIP`, `PATH*` — spawn the **gap-scout** sub-agent (`scripts/gap-scout.md`): it proposes a Sigma translation, validates it against the live API (`scripts/scout-validate.py`), and persists the rule to `~/.powerbi-to-sigma/learned-rules.yaml` (loaded by `scripts/learned-rules.py`) so future conversions auto-apply it. Time-intelligence (YTD/SPLY) is usually translatable — see `refs/measure-patterns.md`, not the scout.

## Phase 3.5 — Reuse an existing DM? (avoid sprawl — mirrors tableau Phase 1.5)
Before posting a NEW data model, check whether an existing Sigma DM already
covers the same warehouse tables (don't add a 4th near-identical "Orders" DM):
```
python3 scripts/pbi-dm-signature.py --bim /tmp/pbix/model.bim --out $WORK/dm-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature $WORK/dm-signature.json \
  --out $WORK/dm-match.json --auto-pick     # exit 0 = candidate ≥ min-score
```
`pbi-dm-signature.py` derives `{warehouse_tables (DB.SCHEMA.TABLE from the M
nav), referenced_columns, measures}` from the model.bim. If a candidate scores
high AND there's no tie, `--auto-pick` recommends reuse (sets `auto_picked:true`
— WARN about inherited columns/RLS/metrics); on a tie it falls back to ASK. To
reuse: skip Phase 4, point the workbook masters at the matched `recommended_dm_id`
+ its element ids (describe it), and continue at Phase 5. Otherwise post new.

## Phase 4 — Post the data model
The converter output (`sigmaDataModel`) needs 3 fixups before `POST /v2/dataModels/spec` (gap `tkd`):
1. **`schemaVersion: 1`** at top level (else `schemaVersion: Invalid 1: undefined`).
2. **`folderId` + `ownerId`** at top level — pull from a reference DM (the **tableau-to-sigma reuse logic**, `find-or-pick-dm.rb`).
3. **Element `name`** on each base warehouse-table element (= `source.path[-1]`) — the converter only names joined View elements, but workbook masters reference DM elements by name.
Then: `tableau-to-sigma/scripts/post-and-readback.rb --type datamodel`. See `refs/spec-fixups.md`.

## Phase 5 — Build the workbook
- **Data page**: one hidden `table` master per DM element used (`source: {kind:data-model, dataModelId, elementId}`, columns `[ElementName/Col]`).
- **Chart elements** source from a master (`source:{kind:table, elementId:<master>}`), columns `[dim, meas]`:
  - bar/line: `xAxis:{columnId}`, `yAxis:{columnIds:[...]}`
  - pie/donut: `color:{id}`, `value:{id}`
  - text: `{kind:text, body:"## ..."}`
  - measure formula wraps the master col: `CountDistinct([Master/Col])`, `Sum([Master/Col])`, date dim `DateTrunc("month",[Master/Col])`.
- `POST /v2/workbooks/spec` (post-and-readback `--type workbook`). Chart-element shapes mirror `tableau-to-sigma/scripts/build-charts-from-signals.rb`.

## Phase 5d — Layout (do NOT skip — stacked ≠ done)
Map each visual's `x,y,w,h` → 24-col grid (`COL_UNIT = page_w/24`, `ROW_UNIT ≈ 30`) → single top-level `layout` XML (one `<Page>` per page, server page IDs) → `tableau-to-sigma/scripts/put-layout.rb`. Math + snap rules in `research/powerbi-visual-layout.md §4`.

## Phase 6 — Verify (mandatory)
- `sigma-mcp-v2 query` each element → confirm real rows (not blank).
- True parity: PBI `POST /v1.0/myorg/groups/{ws}/datasets/{id}/executeQueries` (DAX) vs the same Sigma aggregation. DAX-only; breaks under service-principal if RLS.

## Phase 7 — Bookmarks → per-bookmark workbooks (optional)
PBI bookmarks that **show/hide** or **spotlight** visuals map to Sigma as a
workbook over the bookmark's *visible subset*:
```
python3 scripts/extract-bookmarks.py --pbir-dir /tmp/pbir --out $WORK/bookmarks.json   # or --report-json (classic)
python3 scripts/build-bookmark-workbooks.py --signals $WORK/signals.json \
  --bookmarks $WORK/bookmarks.json --master-map $WORK/master-map.json \
  --data-model <dmId> --folder-id <uuid> --name-prefix "<Report>" --out-dir $WORK/bm
# then POST each $WORK/bm/<name>/workbook-spec.json + put-layout
```
- `extract-bookmarks.py` normalizes each bookmark → `{hidden[], spotlight[], filters_raw}` (reads `definition/bookmarks/*.bookmark.json` shape: `explorationState.sections.<p>.visualContainers.<v>.singleVisual.display.mode` = hidden|spotlight|maximize).
- spotlight → keep ONLY the spotlighted visuals (focus); else all-minus-hidden. The all-visible bookmark = the base workbook.
- **Filter-state bookmarks** (`filters_raw:true`): the `explorationState` filter JSON isn't auto-applied — bake those values as element `filters` / control defaults per the agent's judgment.
- Validated 2026-06-02 on Retail Trends: Overview(8)/KPIs-Only(3)/Trend-Spotlight(1) → 3 workbooks, screenshot-verified.
- `build-bookmark-workbooks.py` is **shared** (lives in `tableau-to-sigma/scripts`, symlinked here) and **vendor-neutral**: `--build-script` selects the signals→workbook builder; a normalized state's `filters: {col:[vals]}` is baked as a `list` filter (`{columnId, kind:list, mode:include, values}`) onto the Data-page **master** so every chart inherits it (page-filter semantics — verified end-to-end). Tableau's analog (Custom Views) feeds the same builder via `tableau-to-sigma/scripts/extract-custom-views.py` — note: Tableau REST exposes custom-view *metadata* only, not filter *values* (opaque state), so Tableau filter recovery needs the view-data-diff technique.

## Reverse direction — author INTO Power BI
The Fabric API is symmetric: `POST .../semanticModels` (TMSL parts) + `POST .../reports` (PBIR) create live items. Same device-code token (`user_impersonation` covers writes). Needs a Fabric-capacity workspace. See `scripts/fabric-auth-check.py` for the write-capability/capacity check.

## Scripts — the conversion pipeline
The conversion is script-driven (mirrors `tableau-to-sigma/scripts/`). `scripts/run.sh` orchestrates connect → extract → convert → post-DM → build-workbook → layout → parity; it runs every deterministic stage and STOPS at the two MCP gates (the `convert_powerbi_to_sigma` conversion and the `sigma-mcp-v2` actuals collection) with a clear instruction, then resume any stage with `--from <stage>`. All scripts are idempotent and re-run-safe.

**Python prereq:** the Microsoft-auth scripts (`fabric-extract.py`, `extract-pbir.py` live-fetch, `phase6-parity-pbi.rb`'s DAX harness) need `msal` + `requests` + `truststore` — pinned in `scripts/requirements.txt`. `run.sh` **bootstraps a venv at `<work-dir>/.venv` automatically** when no suitable interpreter is found; override with `$PBI_PY` (or `migrate-powerbi.rb --python`). No hardcoded developer paths: the local converter build resolves via `--mcp-dir`/`$PBI_MCP_DIR` (falling back to `~/Desktop/sigma-data-model-mcp`, `~/sigma-data-model-mcp`); without one, `migrate-powerbi.rb` gates with instructions to run the `convert_powerbi_to_sigma` MCP **tool** and resume with `--converter-out` (the default converter route).

| Script | Stage | What it does |
|---|---|---|
| `extract-pbir.py` | 1 extract | Fetch a report's PBIR (or parse one already on disk) → normalized `signals.json` (per-visual `sigma_kind` + role bindings + x/y/w/h). The PBI analog of `parse-twb-layout.rb`. |
| `convert-model.rb` | 2–3 convert/post | MODE A prints the exact `convert_powerbi_to_sigma` MCP call for a `model.bim`; MODE B takes the converter output and applies the 3 fixups (schemaVersion + folderId/ownerId via a ref-DM harvest + base-element names) → postable DM spec. |
| `build-workbook-from-pbir.rb` | 4 build | `signals.json` + a `master-map.json` → full workbook spec + 24-col layout XML. Applies the measure-translation patterns in `refs/measure-patterns.md`; **line charts default to a single series** (`beads-sigma-c07`) unless PBI bound a Series/Legend role. **Carries the PBI visual sort** (`f972` — PBIR `query.sortDefinition` / classic `prototypeQuery.OrderBy` → chart `xAxis.sort`/`color.sort`; grouped table → `groupings[0].sort` — element-level sort is rejected on grouped tables). Analog of `build-charts-from-signals.rb`. |
| `phase6-parity-pbi.rb` | 7 parity | executeQueries(DAX) adapter: `--emit-dax` runs the PBI side and writes the parity plan's `expected` rows; `--finalize` injects Sigma actuals and runs the shared `verify-parity.rb`. The PBI analog of Tableau's view-CSV parity adapter. |

The agent authors one PBI-specific artifact: `master-map.json` (maps each PBI Entity → a Data-page master element and each `Entity.Field` queryRef → `{ref, agg}`), which encodes the DM element ids + DAX-measure→Sigma-aggregator decisions. Everything else is mechanical.

**Validated unattended end-to-end 2026-05-31** against the KitchenSink (PBI report `0bebf272` / model `049863fa`, CSA.TJ): `run.sh` drove extract → convert (MCP gate) → post-DM (26 cols, 0 errors) → build → post-WB → **layout** into a throwaway DM + workbook in `tj-wells-1989`. `assert-phase6-ran.rb` passed all 4 gates: **0 `error` columns** (34 live cols), grouped `Department Summary` table (6 depts, real ranked rows), **single-series** YTD line (2025 Jul–Dec = `3536,7412,10932,14700,18080,21844`, parity-exact vs PBI), pivot with `rowsBy`/`values`, and a 12-element grid layout that **survived the final write** (no single-column wipe). Throwaway items deleted after.

> **Phase 5 time-intelligence tradeoff (`beads-sigma-c07`):** the builder emits PBI line charts as a **single series** (`xAxis`=month, `yAxis`=`CumulativeSum(Sum(...))`, **no `color` block**). A continuous `CumulativeSum` reproduces a within-year YTD exactly (2025 matched PBI to the unit) but does NOT reset at the Jan year boundary. For a true `TOTALYTD` per-year-reset on one line, precompute a year-partitioned YTD in a hidden grouped level table and plot it with `Max()` (recipe in `refs/measure-patterns.md §4`). Never reproduce the reset by adding `color:{by:category,column:year}` — that renders TWO lines, diverging from PBI's one.

## Reuse, don't reinvent (and packaging)
These vendor-agnostic Sigma-side scripts are reused: `get-token.sh`, `lib/sigma_rest.rb`, `post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `validate-spec.rb`, `verify-parity.rb`, `cleanup-orphan-workbooks.rb`. In the repo they are **symlinks** into `tableau-to-sigma/scripts/` (DRY), but symlinks break when the skill is downloaded standalone — so always ship via **`./package.sh`**, which dereferences every symlink into a real file and vendors the out-of-tree reference docs into `refs/vendored/`. The result (`dist/powerbi-to-sigma/`) is fully self-contained: 0 symlinks, the whole pipeline runs from inside the bundle. The shared core is being extracted to `sigma-conversion-core` (`beads-sigma-6k9`); until then, package before distributing.


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_powerbi_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Power BI:** `model.roles[].tablePermissions[].filterExpression` (DAX RLS to attribute/team/email) and `columnPermissions` object-level security (to CLS). Role MEMBERSHIP is bound in the Power BI Service (not the model file) — assign it in Sigma.

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

