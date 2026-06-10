---
name: cognos-to-sigma
description: >-
  Migrate IBM Cognos Analytics content to Sigma. Use when the user has a Cognos
  Data Module, Framework Manager package, or report (Report Studio / CA Reporting)
  and wants to recreate it in Sigma. Converts Data Module JSON → Sigma data model
  and report-spec XML → Sigma workbook, translating the Cognos expression DSL and
  flagging constructs with no clean Sigma analog. Discovery via the CA REST API.
user-invocable: true
---

# Cognos → Sigma migration

Convert a Cognos **Data Module** into a Sigma **data model**, then convert the Cognos
**report** that sits on it into a matching Sigma **workbook**. Translate what maps
cleanly; **flag what doesn't** (runtime macros, running-totals, localization) instead
of emitting wrong logic.

> Read `refs/` before relying on shapes: `design-notes.md` (translation surface + scope),
> `data-module-shape.md` + `report-spec-shape.md` (the real CA JSON/XML structures),
> `expression-dsl.md` (the Cognos-expression → Sigma-formula mapping table).
> For the canonical Sigma data-model + workbook spec shapes, defer to the companion
> `sigma-data-models` / `sigma-workbooks` skills.

---

## Prerequisites

- **Cognos Analytics 11.1+** REST access (on-prem or CA on Cloud). Base path is
  `<host>/bi/v1` (NOT `/api/v1`). Auth = a logged-in session: a **session cookie** +
  the **`X-XSRF-Token`** header. On IBMid-SSO trials you can't log in headlessly —
  grab a live session from the browser (DevTools → Network → any `coreBundle.js`-initiated
  `bi/v1/...` XHR → **Copy as cURL**) and feed its cookie + token to `scripts/cognos-discover.sh`.
- **Sigma** API token (via the `sigma-api` skill) to POST the data model + workbook.
- **Node** for the converter (`converter/`: `npm install` once).

---

## Phase 0 — Discover (CA REST)

```bash
export COGNOS_BASE="https://<host>/bi/v1"
export COGNOS_COOKIE="<cookie string>"   export COGNOS_XSRF="<x-xsrf-token>"
scripts/cognos-discover.sh list   <folderId>          # list a folder's items
scripts/cognos-discover.sh module <moduleId> > m.json # Data Module JSON
scripts/cognos-discover.sh report <reportId> > r.xml  # report-spec XML
```

- Samples folder, modules, and reports are discovered by walking `GET /objects/{id}/items`.
- **Data Module spec**: `GET /bi/v1/metadata/modules/{id}` (NOT `/modules/{id}`, which is empty).
- **Report spec**: `GET /bi/v1/objects/{id}?fields=specification` → the `specification` string is the report XML.
- Prefer **warehouse-backed** modules (built on a Data server connection) over file-backed
  ones — they carry complete schemas. File-backed modules (uploaded `.xlsx`) are a
  *land-in-warehouse-first* case (see Verify/parity).

## Phase 1 — Convert the Data Module → Sigma data model

```bash
cd converter && npm install
node --import tsx/esm cli.ts ../path/to/module.json --connection <SIGMA_CONN> --database <DB> --schema <SCHEMA>
```
Emits the Sigma data-model JSON on stdout; stats + warnings on stderr. Read the
warnings aloud to the user — they are the parts that need manual authoring
(running-totals, cross-element metrics, FIXED-LOD-style calcs, localization).

## Phase 2 — POST the data model + read back ids

POST the JSON to `/v2/dataModels/spec`, then GET it back to capture the real element
and column ids (Sigma reassigns them on POST). Abort on any `type=error` column.
(Use the `sigma-data-models` skill / `post-and-readback` pattern.)

## Phase 3 — Convert the report → Sigma workbook, wired to the DM

```bash
node --import tsx/esm cli.ts ../path/to/report.xml --dm <dataModelId>
```
Each Cognos **list** becomes a Sigma `table` element sourced from the migrated DM
element; dataItems become columns (expressions translated); `prompt(...)` become
controls; `Summary()/Total()` footers become aggregate columns. **Wire the real
element/column ids** from Phase 2's readback into the workbook spec's `source` +
formula prefixes, then POST to `/v2/workbooks/spec`.

## Phase 4 — Verify (and optional parity)

- Confirm every workbook element resolves and queries cleanly (0 `type=error` columns).
- **Parity** (optional, the real proof): land the Cognos source database in the
  warehouse Sigma reads (the GO samples are the canonical IBM `GOSALES`/`GOSALESDW`
  DBs — published, loadable), then confirm the Cognos report's numbers match the
  migrated Sigma workbook to the cent.

---

## What's flagged, never faked

The converter emits a warning (and a readable placeholder) instead of wrong logic for:
runtime **macros** (`#…# prompt(…,'token',…)` — dynamic column/SQL building, e.g. a
"swap measure" picker → model as a control + `Switch`), **running-total / moving-* /
rank / lag / lead** (window funcs with no clean single-column analog), **GetResourceString**
(localization), composite/non-equi **joins**, and **detail/summary filters** (surfaced
to re-create as Sigma filters). **Crosstabs → Sigma pivot-tables** (rows/columns edges →
rowsBy/columnsBy, measure → values) and **charts (RAVE2 `<vizControl>`) → Sigma chart elements**
(bar/column/line/area/pie/donut/combo/scatter via the slot model — see `refs/format-shapes.md`)
ARE converted and live-validated to warehouse parity. Cognos chart types with no native Sigma
analog (map, network, word-cloud, packed-bubble, treemap) fall back to a flagged table.
Drill-through→actions and Framework Manager `.cpf` remain roadmap.
