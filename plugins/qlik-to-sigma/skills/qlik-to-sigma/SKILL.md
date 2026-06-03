---
name: qlik-to-sigma
description: >-
  Convert a Qlik Sense / Qlik Cloud app into a Sigma data model and matching
  workbook. Use when the user has a Qlik Cloud tenant/app and wants to recreate
  it in Sigma. Discovery via qlik-cli (Engine + REST), Qlik-expression →
  Sigma-formula translation via the convert_qlik_to_sigma converter, data model
  + workbook creation via the Sigma REST API, and parity verification against
  the source warehouse. Requires qlik-cli + a Sigma SIGMA_API_TOKEN.
user-invocable: true
---

# Qlik → Sigma Conversion

> **STATUS: VALIDATED end-to-end (2026-06-02).** The full flow below was proven on
> a real migration ("Retail Orders (Qlik)" → Sigma) with **exact parity** to the
> Snowflake source at the data-model, denormalized-element, and workbook-chart
> layers. The `scripts/build-sigma-*.py` are the actual scripts used.

**Read ALL of the following before replying or taking any action:**
- `refs/sigma-build-gotchas.md` — the hard-won spec rules (SQL element, workbook master, YAML responses). **This is the difference between a 2xx that errors at query time and a working migration.**
- The **Sigma data model converter MCP** ([github.com/twells89/sigma-data-model-mcp](https://github.com/twells89/sigma-data-model-mcp)) — provides the `convert_qlik_to_sigma` tool and documents the Sigma DM spec correctness rules.
- The Sigma OpenAPI + the `sigma-workbooks` skill — canonical workbook spec. If `sigma-workbooks` is installed, defer to it; otherwise `refs/sigma-build-gotchas.md` here is self-sufficient for this migration.

---

## The one big idea

Qlik's calc language (master measures/dimensions, Set Analysis) translates via the
existing **`mcp__sigma-data-model__convert_qlik_to_sigma`** tool. But the decisive
move is **what you feed it**: the Qlik *in-memory model* (post-LOAD-script field
names), NOT the raw warehouse tables. The Qlik LOAD script's renames/drops are
exactly what disambiguate a clean star; raw warehouse column names collide
(CITY/STATE/REGION/UNIT_COST shared across dims → spurious relationships).

The Qlik LOAD script ≈ a Sigma **custom-SQL element**. Reproduce it as SQL and
every Qlik field name resolves.

---

## Prerequisites

### Qlik access (see `refs/connection.md`)
qlik-cli context (OAuth M2M or API key). `qlik context use <ctx>`.
> **M2M reload limit:** a plain M2M bot cannot reload an app that uses a space
> data-connection ("Connector not found"). Reload as a real user or via M2M
> impersonation. (Discovery/extraction works fine under M2M.)

### Sigma access
```bash
bash -c 'eval "$(scripts/vendor/get-token.sh)"; <cmd>'   # sets SIGMA_BASE_URL + SIGMA_API_TOKEN (exchanges SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET)
```
Need a Sigma connection pointing at the same warehouse as the Qlik app (for parity).
Set `SIGMA_CONNECTION_ID` to **your** connection id (Sigma UI → Connections). *(For reference,
our worked example used a Snowflake connection over the `CSA.TJ` retail schema — substitute your own.)*

---

## Phase 1 — Discover (qlik-cli)
Extract from the app (`qlik app ...`):
- **Data model** — tables + fields. Source of truth = the **load script** (`qlik app script get`); it encodes renames/joins/drops. Capture the effective table→field map (post-rename).
- **Master measures** — `qMeasure.qDef` (Qlik expressions) + label. (List via the engine; for known ids `qlik app object get <id>`.)
- **Master dimensions** — simple field refs are skipped by the converter (already columns); only *calculated* dims become calc columns.
- **Sheets / charts** — `qlik app object get <id>` → `qHyperCubeDef` (dimensions + measures + chart type) per viz.
Assemble into the converter's input JSON (`refs/example-converter-input.json`):
`{appName, tables:[{name, noOfRows, fields:[{name}]}], masterMeasures:[{title,qDef}], masterDimensions:[]}`.
**Use the post-rename Qlik field names** so relationships come out clean.

## Phase 2 — Translate (convert_qlik_to_sigma)
Call `mcp__sigma-data-model__convert_qlik_to_sigma(model_json, connection_id, database, schema)`.
Output = Sigma DM spec (warehouse-table elements + relationships on shared keys +
metrics from measures + auto "Dim View" denormalized elements). Set Analysis is
flagged + omitted (→ Sigma `SumIf`/`CountIf` cross-element; defer or hand-add).

## Phase 3 — Build the Sigma data model  (`scripts/build-sigma-dm.py`)
Reconcile the converter output to the real warehouse and POST:
- Map Qlik-renamed fields → real warehouse columns (e.g. `STORE_KEY`→`ORDER_STORE_KEY`, `CUSTOMER_REGION`→`REGION`). Relationships are by column-**id**, so they survive the repoint.
- Add a **denormalized custom-SQL element** reproducing the LOAD joins — the bulletproof master for workbook charts. SQL-element rules in `refs/sigma-build-gotchas.md`.
- POST `/v2/dataModels/spec` body `{folderId, schemaVersion:1, ...spec}`.
- **Verify (hard gate):** `describe(datamodel-element)` — every column a concrete type, no `error`; then `query` the metrics and compare to a warehouse baseline.

## Phase 4 — Build the workbook  (`scripts/build-sigma-workbook.py`)
Recreate the Qlik sheet(s): a hidden "Data" page master table sourced from the
denormalized DM element, then KPI/bar/line/table charts sourcing the master.
Element shapes + the `source.dataModelId` requirement in `refs/sigma-build-gotchas.md`.
POST `/v2/workbooks/spec`.

## Phase 5 — Parity (hard gate)
Pull the source baseline from the warehouse (the same Snowflake the Qlik app loaded
from) and compare to Sigma `query` results — at the metric level AND per chart
(group-by). Migration is GREEN only on a match. (First run matched to the cent.)

---

## Scripts
| Script | Phase | Purpose |
|---|---|---|
| `scripts/qlik-discover.py` | 1 | Extract data model (load script), master measures/dimensions (Engine MeasureList/DimensionList), and sheets/charts from any app → `converter-input.json`. **Validated.** |
| `scripts/reconcile-columns.py` | 3 | Auto-derive the Qlik-field → real-warehouse-column map from the load script's `AS` aliases + `FROM` tables (so the DM points at real columns). **Validated.** |
| `scripts/gen-denorm-sql.py` | 3 | Turn reconcile.json into the denormalized SQL element (`real AS qlik` + inferred fact↔dim joins) — feeds `build-sigma-dm.py`. **Validated.** |
| `scripts/batch-migrate.py` | 3–6 | Migrate many apps in one pass (one Sigma workbook each, reusing a DM) incl. the reusable `auto_layout()` heuristic (KPIs top row, charts 2-wide grid). **Validated on 5 apps.** |
| `scripts/gap-scout.md` | 2 | Sub-agent guide: for each unhandled Qlik expression (`Aggr`/`Dual`/selection-state/`Range*`/`Class`), spawn a scout to find + validate a Sigma translation and persist it. |
| `scripts/scout-validate.py` | 2 | Gap-scout primitive: validate a candidate formula via a throwaway test workbook (column-type check) + persist to `~/.qlik-to-sigma/learned-rules.yaml`. **Validated.** |
| `scripts/learned-rules.py` | 2 | Loader: the build step applies customer-accumulated rules before falling back to a WARN. |
| `scripts/qlik-screenshot.py` | 1/6 | Export PNGs of a sheet's charts (or specific viz ids) via the Qlik reporting API, for before/after capture. **Validated** (per-viz PNG; whole-sheet is PDF only). |
| `scripts/build-sigma-dm.py` | 3 | Author + POST the Sigma data model (star + relationships + metrics + denorm SQL element). **Proven.** |
| `scripts/build-sigma-workbook.py` | 4 | Author + POST the workbook (master + KPIs + charts). **Proven.** |
| `refs/example-converter-input.json` | 1–2 | The exact convert_qlik_to_sigma input from the first migration. |

`qlik-discover.py --app <id>` enumerates master items via a temporary
`MeasureList`/`DimensionList` object (create → layout → remove; briefly saves the
app and cleans up) — qlik-cli's `object ls` does NOT list master items. The two
`build-sigma-*.py` are the literal scripts from the validated migration, parameterized
by DM/element/connection IDs at the top; generalize the table/column maps per app.

## Open work
- ✅ Set Analysis → Sigma `SumIf` — validated (Holiday Revenue, exact parity). Put the flag column on the denorm element so it's not cross-element.
- ✅ Phase-3 reconciliation — `scripts/reconcile-columns.py` auto-derives it from the load-script `AS` aliases.
- ✅ Before/after PNGs — `scripts/qlik-screenshot.py` (Qlik reporting API).
- Companion `qlik-assessment` skill — built (sibling dir).
- Remaining: feed the reconcile map directly into `build-sigma-dm.py` (currently the SQL element is hand-written); auto-place charts (layout heuristics) instead of fixed grids.
