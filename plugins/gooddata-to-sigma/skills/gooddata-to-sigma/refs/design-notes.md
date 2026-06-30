# gooddata-to-sigma — architecture, parity, risks, build order

## Pipeline (mirrors the sibling converters)

```
Phase 0  Assess        gooddata-assessment: inventory + readiness readout
Phase 1  Discover      discover.py → GET /api/v1/layout/workspaces/{id} → workspace_layout.json
Phase 2  Data model    LDM datasets/attributes/facts/references → Sigma DM
                        MAQL metrics → Sigma DM metrics/formulas (maql-mapping.md)
                        recover warehouse path from dataSource → same connection for parity
Phase 3  Workbook      insights → elements, dashboards → pages + layout (viz-type-mapping.md)
                        filterContext → controls; defer chart authoring to sigma-workbooks
Phase 4  Parity        post-and-readback + assert-parity vs the SAME warehouse
Phase 5  Repoint        finalize workbook sources onto the built DM (never skip)
Phase 6  Enhance/QA    mandatory visual-QA PNG gate; theme via theme-registry
```

## What's new code vs reused

**New** (this repo): GoodData declarative client (`discover.py`), LDM→DM mapper,
**MAQL translator** (the hard part), insight/dashboard→workbook signal builder,
the assessment scanner.

**Reused** (from sigma-migration-skills/shared + sigma-workbooks): the workbook
spec authoring (sigma-workbooks), `find-or-pick-dm`, `build-charts-from-signals`,
layout `decollide_bands` + visual-QA gate, `gap-scout` / `learned-rules` /
`escalate-gap`, the RLS detect→ask→provision→emit gate, the theme registry, and
the `convert_*_to_sigma_formula` plumbing the MAQL translator extends.

Also: a `convert_gooddata_to_sigma` MCP converter + browser mirror, kept in sync
(per the cross-converter convention).

## RLS — user data filters (UDF)

GoodData **User Data Filters** restrict rows per user via a `maql` predicate +
user assignments (the Cloud equivalent of legacy MUF). Maps to the established
Sigma pattern: detect UDFs → map the predicate attribute to a Sigma
**user attribute** → emit a DM filter `CurrentUserAttributeText("x") = [Col]` →
one consolidated gate, opt-in/out, never silent. Workspace Data Filters
(multi-tenant child-workspace column filter) → a single user-attribute filter on
the tenant column.

## Date dimensions & FOR PREVIOUS — LIVE-VALIDATED, exact parity (all via API)

**Closed 2026-06-22, entirely via the API (no UI).** GoodData date dimension +
`FOR PREVIOUS` metric built through the declarative/entity APIs; migrated to a
Sigma monthly-trend element whose `DateLookback` prior-month column matches the
Snowflake monthly baseline **exactly** (2024-02 prev = 2,947.38 = Jan, etc.).

Cracked recipe:
- **Date reference shape** (the blocker): a dataset links a date dimension via a
  normal `references` entry with `identifier.type: "dataset"` (pointing at the
  dateInstance id) and a DATE source column whose **`sources[].target.type` is
  `"date"`** (NOT `"dateInstance"` — that was the 400). `dateInstances[]` defines
  the dimension (`granularities: DAY/WEEK/MONTH/QUARTER/YEAR`). Put the date ref
  on the dataset that owns a DATE column (here `DATE_DIM.FULL_DATE`); bridge the
  fact via a normal `order→DATE_DIM` reference on the INT key.
- **MAQL time metric:** `SELECT {metric/m_net_revenue} FOR PREVIOUS({label/order_date.month})`.
- **Converter (`convert.py`):** skip date references when building Sigma
  *relationships* (target.type=="date") — the date column is just a plain column
  (the FK-column pass already surfaces `FULL_DATE` as a column, reachable from
  the fact via the `DATE_DIM` relationship).
- **Sigma output:** date-grouped element (`DateTrunc("month", [FACT/DATE_DIM/Full Date])`)
  with `DateLookback(Sum([FACT/Net Revenue]), [Month], 1, "month")` for prior month.
  **`build_workbook` now AUTO-emits this** for any `FOR PREVIOUS/NEXT` metric —
  date-grouped table (`DateTrunc`) + `DateLookback(base, [Period], n, unit)` —
  validated at exact prior-month parity (no hand-authoring).

Original findings (for reference):

- **GoodData date dimensions are "Date datasets" = `dateInstances`** in the LDM.
  `granularities` enum (validated): `MINUTE, HOUR, DAY, WEEK, MONTH, QUARTER,
  YEAR, MINUTE_OF_HOUR, HOUR_OF_DAY, DAY_OF_WEEK, DAY_OF_MONTH, DAY_OF_QUARTER,
  DAY_OF_YEAR, WEEK_OF_YEAR, MONTH_OF_YEAR, QUARTER_OF_YEAR, FISCAL_MONTH,
  FISCAL_QUARTER, FISCAL_YEAR` (NOT `WEEK_SUN_SAT`).
- **A date link is NOT a normal `references` entry.** A `references[].identifier.type`
  only accepts `dataset` (rejects `dateInstance`). Auto-generated models link a
  date dimension by a **column-naming convention** (`d__date`, with a granularity
  suffix like `d__date__day`), so the manual declarative date-reference shape
  still needs to be harvested from a real workspace that has one (build a date
  dim in the UI once, GET the LDM) — same harvest-from-example tactic used for
  plugins/themes elsewhere.
- **`ORDER_FACT` exposes only INT date keys** (`ORDER_DATE_KEY` YYYYMMDD, no DATE
  column). Two ways to get a DATE: a SQL-backed dataset that casts it, or join
  `CSA.TJ.DATE_DIM` (has `FULL_DATE` DATE + `DATE_KEY`).
- **Converter work to add:** `dateInstance` → a Sigma date column (parse YYYYMMDD
  via the date DSL, or use the joined `FULL_DATE`); `FOR PREVIOUS` →
  `DateLookback(<measure>, "month", -1)` in a date-grouped workbook element
  (build_workbook addition). Parity target: prior-period net revenue vs Snowflake.

## Dashboard layout (implemented)

`build_workbook` emits one Sigma page per GoodData dashboard and a top-level
`layout` XML built from the dashboard's own grid: each `layout.sections[]` → a row
band, each widget's `size.xl.gridWidth` (GoodData 12-col) → a Sigma 24-col span
(×2), KPIs short / charts+tables taller. Applied as the LAST write (a bare spec
stacks every element full-width). Non-dashboard auto-elements (e.g. the FOR
PREVIOUS trend) go on an "Other" page. Rendered result: KPI strip + 2-up charts,
structurally faithful to the source dashboard. (Pixel side-by-side pending — the
GoodData trial visual-export API 500'd; layout is derived from the dashboard spec
so it mirrors by construction.)

## Parity strategy

GoodData Cloud computes on the customer warehouse, so the same-warehouse parity
play works. Caveats to prove out live:
- **FlexQuery / compute-only metrics** may have no clean SQL equivalent — flag,
  don't fake; confirm which MAQL constructs round-trip to warehouse SQL.
- Apply dashboard `filterContext` when checking insight totals.
- `sql`-backed datasets → **warehouse-table on the FROM table** (implemented).
  Sigma's spec API can't resolve columns on a `kind:"sql"` source (it would have to
  RUN the query to discover output columns — the known custom-SQL-via-spec
  limitation), so convert.py maps a SQL dataset to a warehouse-table on its parsed,
  db-qualified FROM table. SQL-derived alias columns (a synthetic grain key) are
  translated to Sigma formulas (`||`→`&`, `CAST(x AS VARCHAR)`→`Text(x)`, bare
  idents→`[TABLE/col]`, quote-aware); passthrough columns map straight through;
  anything untranslatable is flagged. Composite-key facts need this (GoodData
  requires a single-attribute grain → a synthetic key in SQL).

## References — two GoodData shapes (both handled)

convert.py reads BOTH `references[]` shapes: legacy `sources:[{column,target:{id,type}}]`
(incl. dateInstance links via `target.type=="date"`) AND current GoodData Cloud
`sourceColumns:["FK_COL"]` whose target is the **referenced dataset's grain**
attribute. References whose target isn't a dataset (a dateInstance/date-dimension
link) are skipped — the date column stays a plain column. A fresh convert rebuilds
relationships under either shape (they were silently lost when only `sources` was read).

## Dashboard date filter → a Sigma control (not baked predicates)

A dashboard's relative date filter (`filterContext`) becomes ONE Sigma `date-range`
control over a **hidden master detail table** that every KPI/chart/pivot sources;
the filter propagates down the source lineage to all elements — including the pivot,
which can't honor a direct element filter (the "filter the SOURCE, not the pivot"
path around the pivot-filter-drop bug). GoodData relative `{month, from 0, to 0}` →
`mode:current, unit:month` ("this month"); `from==to==-n` → `mode:last`. The master's
date column is parsed from the YYYYMMDD key with `MakeDate(y,m,d)` (NOT `Date()` —
that fails the export). Keeps the migrated dashboard interactive, mirroring GoodData.

## Risks (ranked)

1. **MAQL coverage** — `BY` / `BY ALL` / `WITHIN` context + `FOR` time intel.
   Build gap-scout first so coverage is measured, not assumed.
2. **Compute-engine-only metrics** — no warehouse equivalent → flag set.
3. **Cloud vs classic Platform** API divergence — Cloud first; classic deferred.
4. **Dashboard layout fidelity** — responsive grid, not pixels; map to Sigma grid.
5. **Exotic visualizations** (funnel/sankey/waterfall/treemap) → flagged tables.

## Build order

1. **Trial + live discovery** — GoodData Cloud trial, validate token auth +
   `GET /layout/workspaces/{id}`, dump a real workspace as the fixture
   (ThoughtSpot/Sisense bootstrap pattern).
2. LDM→DM mapper + plain-MAQL translator → first live DM with parity.
3. Insights→workbook (headline/table/bar/line first) → first live workbook.
4. MAQL context + time intel (gap-scout-driven).
5. Dashboards→layout, filterContext→controls, UDF→RLS.
6. Assessment skill readout; then graduate into sigma-migration-skills/plugins/.

## Scope note

GoodData **Cloud / .CN** only for v0.1. Legacy **GoodData Platform**
(`/gdc/md/{project}`, classic MAQL dialect, MUF) is a separate extraction client
— documented fast-follow, not built.
