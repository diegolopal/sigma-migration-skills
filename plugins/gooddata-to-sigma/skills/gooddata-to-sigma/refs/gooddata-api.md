# GoodData Cloud / .CN — extraction API (research spike, verified June 2026)

> Source of truth: GoodData Cloud public docs (declarative interface, API
> reference) + `gooddata-sdk`. Endpoints below verified from docs; **not yet
> exercised against a live workspace** — the first build step validates them on
> a trial.

## Products & which API

| Product | API | Targeted? |
|---|---|---|
| **GoodData Cloud** (SaaS) | `/api/v1` REST + declarative layout | ✅ primary |
| **GoodData.CN** (containerized) | same `/api/v1` + declarative layout | ✅ same code path |
| **GoodData Platform** (classic / "bear", `/gdc/md/{project}`) | different REST, MUF user filters | ⏳ fast-follow only |

Cloud and .CN share the API and the declarative model, so one client covers
both. Classic Platform is a separate extraction client — deferred.

## Auth

Bearer **API token** (personal access token created in the GoodData UI /
organization API). Every call:

```
Authorization: Bearer <API_TOKEN>
```

Base URL is the org host, e.g. `https://<org>.cloud.gooddata.com`. The
`gooddata-sdk` (Python) wraps all of this — `GoodDataSdk.create(host, token)`.

## The win: declarative workspace export

One call returns the **entire workspace** — LDM *and* analytics — as JSON:

```
GET  {HOST}/api/v1/layout/workspaces/{workspaceId}              # full
GET  {HOST}/api/v1/layout/workspaces/{workspaceId}/logicalModel # LDM only
GET  {HOST}/api/v1/layout/workspaces/{workspaceId}/analyticsModel# analytics only
GET  {HOST}/api/v1/layout/workspaces                            # all workspaces
```

Add `?exclude=ACTIVITY_INFO` to drop author/editor metadata. (Declarative API
is GET/PUT, all-in-one document; the Entity API — `/api/v1/entities/...` — is
the per-object alternative if we ever need finer reads.)

### Top-level shape

```jsonc
{
  "ldm": {
    "datasets": [ /* dataset: id, title, attributes[], facts[], references[],
                     dataSourceTableId / sql, grain, primaryKey */ ],
    "dateInstances": [ /* date dimensions + granularities */ ]
  },
  "analytics": {
    "metrics":              [ /* { id, title, content: { maql, format } } */ ],
    "visualizationObjects": [ /* insights — see viz-type-mapping.md */ ],
    "analyticalDashboards": [ /* layout: sections -> items -> widget; filterContext */ ],
    "filterContexts":       [ /* saved filter state referenced by dashboards */ ]
  }
}
```

### LDM building blocks (`ldm.datasets[]`)

- **dataset** — maps to one warehouse table via `dataSourceTableId` (or inline
  `sql`). This recovers the Sigma source path (DB/schema/table) — same idea as
  recovering the warehouse FQN in the other converters.
- **attribute** — a dimension; has one or more **labels** (display forms); the
  default label is the dimension column, alternates are extra columns.
- **fact** — a numeric, aggregatable column.
- **reference** — FK from one dataset to another (and to date instances) →
  Sigma **relationship**.
- **dateInstance** — a date dimension exposing granularities (day/week/month/
  quarter/year) → Sigma date column + truncations.

### Data source

The workspace's `dataSource` (separate `/api/v1/entities/dataSources/...`)
holds the warehouse type + connection. We recover the physical table path from
the dataset mapping and point the Sigma DM at the **same** connection for parity.

## Object id references

Everywhere in MAQL and insights, objects are referenced by typed id:
`{fact/<id>}`, `{metric/<id>}`, `{label/<id>}`, `{attribute/<id>}`. The
declarative export carries these ids, so cross-references resolve without name
matching.

## Not in the API (expected weak spots)

- **Usage telemetry** — like every other tool, per-insight/dashboard view
  counts are not in the declarative model; if needed, pull from audit logs
  separately. (Universal assessment weak spot.)
- **Pixel layout fidelity** — dashboard layout is a responsive section/grid, not
  absolute coordinates; map to Sigma's grid, don't chase pixels.

## Open items to confirm live (first build step)

1. Exact `dataset.dataSourceTableId` → warehouse `[DB, SCHEMA, TABLE]` shape.
2. Whether `sql`-backed datasets (custom SQL) appear inline → Sigma Custom-SQL
   element vs warehouse-table source.
3. `metrics[].content.format` string → Sigma number format mapping.
4. UDF (user data filter) export location + MAQL shape (see design-notes RLS).
