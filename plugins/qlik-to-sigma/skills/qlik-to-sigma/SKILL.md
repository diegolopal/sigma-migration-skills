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

> **STATUS: VALIDATED end-to-end (2026-06-02; generalized + re-validated 2026-06-10).**
> The full flow below was proven on a real migration ("Retail Orders (Qlik)" → Sigma)
> with **exact parity** to the Snowflake source at the data-model, denormalized-element,
> and workbook-chart layers — and the 2026-06-10 run produced the multi-page workbook
> (one Sigma page per Qlik sheet, layout straight from the sheet cell grids) from ONE
> command with zero hand-edits in under 2 minutes.

## The one command

```bash
eval "$(scripts/vendor/get-token.sh)"          # SIGMA_BASE_URL + SIGMA_API_TOKEN
ruby scripts/migrate-qlik.rb \
  --app <qlikAppId> --connection <SIGMA_CONNECTION_ID> \
  --database <DB> --schema <SCHEMA> --context <qlik-cli ctx> \
  [--folder <SIGMA_FOLDER_ID>] [--name '<prefix>'] [--yes]
```

discover → convert → data model → workbook → layout → parity, for ANY app, driven
entirely by the discovery artifacts (no app-specific edits). Exit 10 = genuine human
decisions printed as an OPEN QUESTIONS block (re-run with `--yes` or `--answers`);
exit 0 = PARITY GREEN; exit 3 = built but parity RED. Each phase below is also an
independently runnable script if you need to intervene mid-pipeline.

**Offline smoke (no tenant/org/network):** `ruby scripts/migrate-qlik.rb
--from-discovery fixtures/retail-orders --connection 0000… --dry-run --yes --out /tmp/smoke`
— see `fixtures/README.md`.

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
bash -c 'eval "$(scripts/vendor/get-token.sh)"; <cmd>'   # sets SIGMA_BASE_URL + SIGMA_API_TOKEN
```
Need a Sigma connection pointing at the same warehouse as the Qlik app (for parity).
The verified CSA.TJ connection is `cb2f5180-641f-47bd-8efa-da9d590d855a` (Snowflake ymb68310).

---

## Phase 1 — Discover (qlik-cli)
`scripts/qlik-discover.py --app <id> --context <ctx> --out WORK` extracts:
- **Data model** — tables + fields. Source of truth = the **load script** (`qlik app script get`); it encodes renames/joins/drops. Capture the effective table→field map (post-rename).
- **Master measures** — `qMeasure.qDef` (Qlik expressions) + label. (List via the engine; for known ids `qlik app object get <id>`.)
- **Master dimensions** — simple field refs are skipped by the converter (already columns); only *calculated* dims become calc columns.
- **Sheets / charts** (`charts.json`) — per object: vizType, title, owning sheet, dims (raw field defs + labels + qNullSuppression), measures (exprs + labels + Qlik number formats), sort definition.
- **Sheet cell grids** (`layout.json`) — per sheet: `columns`×`rows` grid + every object's `col/row/colspan/rowspan`. The workbook step maps this 1:1 onto Sigma's 24-col grid (row-scale ≥2 so labels render; KPIs bumped to ≥5 rows).
- **App freshness** (`app-meta.json` + `snapshot.json`) — `lastReloadTime`, Section Access / DirectQuery flags, plus a Qlik-engine `eval` snapshot of every sheet KPI and Max(date) — read-only, no reload.
Assemble into the converter's input JSON (`refs/example-converter-input.json`):
`{appName, tables:[{name, noOfRows, fields:[{name}]}], masterMeasures:[{title,qDef}], masterDimensions:[]}`.
**Use the post-rename Qlik field names** so relationships come out clean.

### Discovery speed & safety (customer scale — 20-40+ apps)
Discovery is **fully parallel and strictly read-only** (re-engineered 2026-06-11):
- All engine/REST fetches share one pool (`--pool`, default 8) bounded by a
  single global semaphore — the per-object `properties` loop was the serial
  bottleneck (46 × ~1.2s). Measured on the 46-object fixture app:
  **57.3s serial → 12.5s full / 8.4s with `--defer-snapshot`** (≈4.6×). Per-app
  cost scales with pool width, not object count — a 40-app estate's discovery
  drops from ~38 min to ~6 min of source-side wall clock.
- **Zero app writes**: master items are enumerated via read-only
  `qlik app measure/dimension ls` + per-item `properties`. The old temp
  MeasureList/DimensionList object briefly SAVED the app — bumping
  `modifiedDate` on every discovery (verified live: old run bumps it, three
  new-mode runs leave it untouched). Discovery never reloads, never writes.
- **Engine-snapshot lane**: the KPI/max-date/bucket evals (`snapshot.json`) are
  consumed only at the Phase-6 freshness banner, and in-memory totals can't
  change without a reload — so `migrate-qlik.rb` runs discovery with
  `--defer-snapshot` and computes the snapshot via `--snapshot-only` as a
  background lane under Phases 2-5.
- **Throttle handling (never silent)**: Qlik Cloud throttles new engine
  sessions after rapid bursts ("could not connect to engine"). Transient
  errors retry with exponential backoff; anything still missing after a pooled
  + serial second pass **aborts discovery (exit 4)** rather than silently
  building a workbook with missing sheets/charts. `timings.json` (and
  `timings-snapshot.json`) record per-stage wall-clock + retry counts on every
  run.

### Phase 1.5 — SOURCE-FRESHNESS PREFLIGHT (never skip)
Before ANY side-by-side, compare the app's `lastReloadTime` + in-memory snapshot
against the live warehouse. Qlik shows a **reload-time snapshot**; Sigma queries the
warehouse **live** — a stale app makes every total differ and looks like a conversion
bug if you don't lead with it. The orchestrator prints the staleness up front
("Qlik app last reloaded N days ago") and Phase 6 leads its handoff with the explicit
comparison, e.g. *"Qlik is ~8 days stale; Sigma will show more data (Qlik 106,723.34 /
620 orders vs warehouse 110,342.75 / 648)"* — classifying each KPI delta as
MATCH / STALE-EXPLAINED / DIVERGENT. Offer the user the option to reload/repoint the
Qlik app first if they need matching snapshots. Only DIVERGENT (delta NOT explained by
staleness) blocks GREEN.

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

## Phase 2.5 — Reuse an existing DM? (avoid sprawl — mirrors tableau Phase 1.5)
Before building a NEW data model in Phase 3, check whether an existing Sigma DM already
covers the same warehouse tables (don't add a 4th near-identical "Orders" DM):
```bash
python3 scripts/qlik-dm-signature.py --model converter-input.json \
  --database <DB> --schema <SCHEMA> --out $WORK/dm-signature.json
eval "$(scripts/vendor/get-token.sh)"       # SIGMA_BASE_URL + SIGMA_API_TOKEN
ruby scripts/vendor/find-or-pick-dm.rb --workbook-signature $WORK/dm-signature.json \
  --out $WORK/dm-match.json --auto-pick     # exit 0 = candidate ≥ min-score
```
`qlik-dm-signature.py` derives `{warehouse_tables, referenced_columns, measures}` from the
Phase-1 converter input (pass the same `--database`/`--schema` you hand the converter —
Qlik table names are bare). Decision:
- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, the matched
  cols (N/M) and the inherited-extras warning from `dm-match.json`. If they reuse, run a
  **shape preflight** first — read the candidate DM's spec back and confirm every column
  the workbook needs resolves on the element you'll wire to (no `error` types, fact vs dim
  location) — then skip Phase 3 and point Phase 4's masters at the matched
  `recommended_dm_id` + its element ids. With `--auto-pick` a clear winner (no tie within
  0.05) skips the prompt — still WARN about inherited columns/RLS/metrics.
- **Score < 0.6** → build new (Phase 3) and TELL the user no reusable DM was found.

## Phase 3 — Build the Sigma data model  (`scripts/build-sigma-dm.py`)
Artifact-driven (NO baked-in table maps or SQL): consumes `converter-out.json` +
`reconcile.json` (from `reconcile-columns.py`) + `denorm.json` (from
`gen-denorm-sql.py`):
- The converter's warehouse-table **star elements are repointed** via reconcile: path
  tail Qlik-table → real table (`OrderFact`→`ORDER_FACT`), column formulas
  `[REAL_TABLE/<real col display>]` with the Qlik field name kept as the display name.
  Relationships are by column-**id**, so they survive the repoint. LOAD-expression
  fields are dropped + reported.
- The **denormalized custom-SQL element** (reproducing the LOAD joins) — the
  bulletproof master for workbook charts; SQL-element rules in `refs/sigma-build-gotchas.md`.
- The converter's **metrics are hosted on the denorm element** (it carries every
  field → no cross-element errors); unresolvable ones dropped + reported. Original
  Qlik exprs kept as metric descriptions.
- Display names follow **Sigma's own derivation rule** (lowercase particles:
  `DAYS_TO_SHIP` → "Days to Ship", NOT "Days To Ship" — verified against a live DM
  readback 2026-06-10), so refs line up with Sigma-derived names with no defensive
  describes.
- POST `/v2/dataModels/spec` body `{folderId, schemaVersion:1, ...spec}`; element ids
  are reassigned on save — the script reads back the persisted denorm element id.

## Phase 4 — Build the workbook  (`scripts/build-sigma-workbook.py`)
Artifact-driven: consumes `charts.json` + `layout.json` + `denorm.json` + the DM ids.
Builds a hidden "Data" page master table (every denorm column) sourced from the
denorm DM element, then **one Sigma page per Qlik sheet** with KPI/bar/line/pie/
combo/table elements translated from each object's hypercube (kinds, labels, number
formats, sorts, null-suppression — see the script docstring for the full mapping).
The Qlik cell grid maps 1:1 onto the 24-col Sigma grid. Element shapes + the
`source.dataModelId` requirement in `refs/sigma-build-gotchas.md`.
POST `/v2/workbooks/spec`, then `scripts/vendor/put-layout.rb` applies the layout XML.

## Phase 5 — Parity (hard gate)
Three checks, led by the **freshness banner** (Phase 1.5 — read it before any
side-by-side):
1. **Column resolution** — `GET /v2/workbooks/{id}/columns`: zero `error`-typed columns.
2. **KPI values** — every KPI element's REST CSV export vs the Qlik engine snapshot
   (`qlik app eval`); deltas classified MATCH / STALE-EXPLAINED / DIVERGENT.
3. **Bucket counts (per chart)** — Sigma export row count vs the Qlik hypercube
   cardinality (`Count(distinct dim…)`), so a suppressed/extra null bucket or a
   dim-value-without-facts surfaces **even when every shared cell matches**.
   (Known shape: Qlik shows dimension values with zero fact rows — e.g. a store with
   no orders — that a fact-grain LEFT JOIN can never emit; that's data shape, not a bug.)
GREEN = all columns resolve + no DIVERGENT KPI. Bucket mismatches WARN loudly with
the likely cause. (First run matched to the cent; staleness-explained deltas don't block.)

> **Querying for parity:** `metric('<id>', t)` against a data-model element can return
> "Missing Metric" — aggregate the element's raw columns directly instead
> (`SUM("<colId>")`/`COUNT(DISTINCT ...)`), or use the REST export API. See
> `refs/sigma-build-gotchas.md` → Metrics.

---

## Scripts
| Script | Phase | Purpose |
|---|---|---|
| `scripts/qlik-discover.py` | 1 | Extract data model (load script), master measures/dimensions (read-only `measure/dimension ls` + properties), and sheets/charts from any app → `converter-input.json`. Pooled (`--pool 8`), strictly read-only, `--defer-snapshot`/`--snapshot-only` lanes, `timings.json` evidence. **Validated (57.3s → 12.5s on the 46-object fixture app).** |
| `scripts/qlik-dm-signature.py` | 2.5 | Converter-input JSON → DM-reuse signature (`{warehouse_tables, referenced_columns, measures}`) for `find-or-pick-dm.rb`. **Validated live.** |
| `scripts/vendor/find-or-pick-dm.rb` | 2.5 | Scan existing Sigma DMs and recommend reuse (score = 0.7·column + 0.2·table + 0.1·metric overlap; `--auto-pick` with tie-window safety). Shared vendor-neutral copy (canonical: tableau-to-sigma). Non-destructive. |
| `scripts/migrate-qlik.rb` | ALL | **The one command** — chains every phase below for any app/sheet; OPEN-QUESTIONS checkpoint, freshness preflight, bucket parity; `--from-discovery` + `--dry-run` = offline smoke. Discovery runs as a background lane with Sigma-side prep (token, folder, DM-spec prefetch for Phase 2.5) interleaved in the foreground; the engine snapshot runs as its own lane under Phases 2-5; `PHASE TIMINGS` printed at exit. **Validated live 2026-06-11 (68s wall, zero hand-edits, GREEN incl. layout lint).** |
| `scripts/reconcile-columns.py` | 3 | Auto-derive the Qlik-field → real-warehouse-column map from the load script's `AS` aliases + `FROM` tables (so the DM points at real columns). **Validated.** |
| `scripts/gen-denorm-sql.py` | 3 | Turn reconcile.json into the denormalized SQL element (`real AS qlik` + inferred fact↔dim joins) — feeds `build-sigma-dm.py`. Display names match Sigma's own derivation rule. **Validated.** |
| `scripts/batch-migrate.py` | 3–6 | Migrate many apps in one pass (one Sigma workbook each, reusing a SHARED DM) — for tenant-scale demos. For distinct apps, run `migrate-qlik.rb` per app. **Validated on 5 apps.** |
| `scripts/gap-scout.md` | 2 | Sub-agent guide: for each unhandled Qlik expression (`Aggr`/`Dual`/selection-state/`Range*`/`Class`), spawn a scout to find + validate a Sigma translation and persist it. |
| `scripts/scout-validate.py` | 2 | Gap-scout primitive: validate a candidate formula via a throwaway test workbook (column-type check) + persist to `~/.qlik-to-sigma/learned-rules.yaml`. **Validated.** |
| `scripts/learned-rules.py` | 2 | Loader: the build step applies customer-accumulated rules before falling back to a WARN. |
| `scripts/qlik-screenshot.py` | 1/6 | Export PNGs of a sheet's charts (or specific viz ids) via the Qlik reporting API, for before/after capture. **Validated** (per-viz PNG; whole-sheet is PDF only). |
| `scripts/build-sigma-dm.py` | 3 | Author + POST the Sigma data model FROM THE PIPELINE ARTIFACTS (converter-out + reconcile + denorm): repointed star + relationships + denorm SQL element + metrics. `--dry-run` for offline. **Proven (generalized 2026-06-10).** |
| `scripts/build-sigma-workbook.py` | 4 | Author + POST the workbook FROM DISCOVERY (charts.json + layout.json): one page per Qlik sheet, cell-grid layout, sorts, formats, null-suppression filters. `--dry-run` for offline. **Proven (generalized 2026-06-10).** |
| `refs/example-converter-input.json` | 1–2 | The exact convert_qlik_to_sigma input from the first migration. |
| `fixtures/retail-orders/` | — | Complete offline discovery+converter input set (sanitized demo app) — see `fixtures/README.md` for the offline smoke path. |

`qlik-discover.py --app <id>` enumerates master items via the read-only
`qlik app measure ls` / `qlik app dimension ls` + per-item `properties`
(qlik-cli's `object ls` does NOT list master items; the old temp
MeasureList/DimensionList object create→rm briefly SAVED the app, bumping its
`modifiedDate` on every discovery — eliminated 2026-06-11). Everything
(incl. `qlik app eval` for the freshness snapshot) is read-only; the app is
never reloaded and never written.

## Open work
- ✅ Set Analysis (simple) → `Sum(If(...))` — auto-translated in the converter + validated live (2026-06-05). Host dim-flag measures on the denorm element.
- ✅ Range\*/Dual/Class/Count(DISTINCT) — auto-translated + validated.
- ✅ `$(var)`/Above/Rank/P()/Aggr — drop+warn (no longer emitted verbatim; previously `$()` POST-blocked the whole DM).
- ✅ Multi-fact metric placement — measures now land on the element that owns their fields (bare-name resolution), not always `elements[0]`.
- ✅ Phase-3 reconciliation — `scripts/reconcile-columns.py` auto-derives it from the load-script `AS` aliases.
- ✅ Before/after PNGs — `scripts/qlik-screenshot.py` (Qlik reporting API).
- ✅ `scout-validate.py` kpi-chart bug fixed (`value.columnId`, was `value.id` → every kpi validation failed POST).
- ✅ One-command pipeline (`migrate-qlik.rb`) — discover→convert→DM→workbook→layout→parity, artifact-driven builders, validated live 2026-06-10.
- ✅ Layout from discovery — per-sheet cell grids → Sigma 24-col grid (row-scale ≥2, KPI ≥5 rows).
- ✅ Source-freshness preflight + per-chart bucket-count parity.
- ✅ Display-name rule matched to Sigma's derivation (lowercase particles), verified by live readback.
- Companion `qlik-assessment` skill — built (sibling dir).
- **Remaining (beads):** multi-fact relationship topology — two facts sharing dim keys still get fact↔fact links/fan-trap (`beads-sigma-uw5c`, relationship half); denorm "View" column bloat/dupes on multi-fact (`beads-sigma-hsua`; the DM build now ships the denorm SQL element INSTEAD of the converter "View" elements); full multi-fact END-TO-END parity needs a real 2nd Snowflake fact + Qlik app (`task`). Aggr() guidance (`beads-sigma-16xc`).


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_qlik_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Qlik:** Section Access (supply the parsed `sectionAccess` object): `REDUCTION` row reduction (to team/attribute RLS; strict-exclusion equals Sigma fail-closed) and `OMIT` column reduction (to CLS).

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

