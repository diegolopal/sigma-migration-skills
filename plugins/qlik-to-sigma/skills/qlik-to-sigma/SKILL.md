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
- The repo `~/Desktop/sigma-data-model-mcp/CLAUDE.md` — Sigma DM spec correctness rules + the verified CSA.TJ test connection.
- `~/sigma-skills/sigma-workbooks/SKILL.md` + the Sigma OpenAPI — canonical workbook spec.

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
bash -c 'eval "$(~/sigma-skills-staging/tableau-to-sigma/scripts/get-token.sh)"; <cmd>'   # sets SIGMA_BASE_URL + SIGMA_API_TOKEN
```
Need a Sigma connection pointing at the same warehouse as the Qlik app (for parity).
The verified CSA.TJ connection is `cb2f5180-641f-47bd-8efa-da9d590d855a` (Snowflake ymb68310).

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

> **Legacy QlikView `.qvw`?** There's no Qlik Cloud API and no `.qvw` parser. Have the
> customer enable "Create project folder" in QlikView Desktop and send the `<name>-prj/`
> folder, then call **`mcp__sigma-data-model__convert_qlikview_prj_to_sigma`** with the
> folder's files (`[{name,content}]` — `LoadScript.txt` + `CH*.xml`). It parses the load
> script (tables/fields incl. `AS` renames) + chart expressions (measures) and runs the
> same Phase-2 translation. No row counts in a `-prj` folder → relationships are by shared
> field name only; review join directions.

## Phase 2 — Translate (convert_qlik_to_sigma)
Call `mcp__sigma-data-model__convert_qlik_to_sigma(model_json, connection_id, database, schema)`.
Output = Sigma DM spec (warehouse-table elements + relationships on shared keys +
metrics from measures + auto "Dim View" denormalized elements).

**Expression coverage (validated against live Sigma 2026-06-05):** the converter now
auto-translates the common Qlik idioms instead of dropping them:
- **Set Analysis (simple)** `Sum({<F={v}>} X)` → `Sum(If([F]=v, [X]))`; `{1}` (ignore
  selections) → plain agg; `{<F-={v}>}` → `<>`; multi-value `{a,b}` → `or`-chain;
  multi-flag → `and`-chain; `Count({<…>} DISTINCT X)` → `CountDistinct(If(…, [X]))`.
- **Row-wise Range\*** (multi-arg): `RangeSum`→`a + b`, `RangeMax`→`Greatest`, `RangeMin`→`Least`, `RangeAvg`→`(a+b)/n`.
- **Dual(text, num)** → numeric arg; **Class(x,n)** → `Floor([x]/n)*n`; **Count(DISTINCT x)** → `CountDistinct(x)`.

**Still dropped (warned, not silently emitted):** `$(var)` dollar-expansion (would
POST-block the whole DM), inter-record `Above/Below/Peek/Previous/RowNo`, ranking
`Rank/HRank`, set-element `P()/E()`, `Aggr()`, `FirstSortedValue`, exotic set modifiers
(search/`$()`/set operators). These → run the **gap-scout** (`scripts/gap-scout.md`).

**Cross-element caveat:** a translated measure whose condition field lives on a *dim*
(e.g. `Sum(If([Is Holiday]=1, [Net Revenue]))`) is placed on the fact element and the
converter emits an `ℹ … references fields from N elements` warning — host that metric on
the **denormalized element** (which carries all fields) or it errors as cross-element.

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

> **Querying for parity:** `metric('<id>', t)` against a data-model element can return
> "Missing Metric" — aggregate the element's raw columns directly instead
> (`SUM("<colId>")`/`COUNT(DISTINCT ...)`), or use the REST export API. See
> `refs/sigma-build-gotchas.md` → Metrics.

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
- ✅ Set Analysis (simple) → `Sum(If(...))` — auto-translated in the converter + validated live (2026-06-05). Host dim-flag measures on the denorm element.
- ✅ Range\*/Dual/Class/Count(DISTINCT) — auto-translated + validated.
- ✅ `$(var)`/Above/Rank/P()/Aggr — drop+warn (no longer emitted verbatim; previously `$()` POST-blocked the whole DM).
- ✅ Multi-fact metric placement — measures now land on the element that owns their fields (bare-name resolution), not always `elements[0]`.
- ✅ Phase-3 reconciliation — `scripts/reconcile-columns.py` auto-derives it from the load-script `AS` aliases.
- ✅ Before/after PNGs — `scripts/qlik-screenshot.py` (Qlik reporting API).
- ✅ `scout-validate.py` kpi-chart bug fixed (`value.columnId`, was `value.id` → every kpi validation failed POST).
- Companion `qlik-assessment` skill — built (sibling dir).
- **Remaining (beads):** multi-fact relationship topology — two facts sharing dim keys still get fact↔fact links/fan-trap (`beads-sigma-uw5c`, relationship half); denorm "View" column bloat/dupes on multi-fact (`beads-sigma-hsua`); full multi-fact END-TO-END parity needs a real 2nd Snowflake fact + Qlik app (`task`). Aggr() guidance (`beads-sigma-16xc`). Feed reconcile map into `build-sigma-dm.py`; auto-layout charts.
