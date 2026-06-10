# CA REST endpoints used by cognos-assessment

All read-only. Base path is **`/bi/v1`** (NOT `/api/v1`). Auth = a logged-in
session **cookie** + the **`X-XSRF-Token`** header (grab both from DevTools →
Network → any `bi/v1/...` request → "Copy as cURL"). Sessions are short-lived —
re-grab when a request 401/403s.

| Need | Endpoint | Notes |
|---|---|---|
| Probe / list a folder | `GET /bi/v1/objects/{id}/items?fields=defaultName,type,id,owner,modificationTime` | `data[]` of `{id,type,defaultName,owner,modificationTime}`. `type` ∈ `folder` / `module` / `report` / `reportView` / `exploration` / `dashboard` / `dataSet2`. Use folder id `.public_folders` for the team-content root. |
| Pagination | append `&top=100&skip=N` | Loop, incrementing `skip` by the page size, until a short page comes back. |
| **Data Module JSON** | `GET /bi/v1/metadata/modules/{id}` | The full module spec. `GET /modules/{id}` (no `metadata`) returns EMPTY — wrong endpoint. |
| **Report-spec XML** | `GET /bi/v1/objects/{id}?fields=specification` | `data[0].specification` is the report XML string (schema 17.x). Same for `reportView`. |

Headers on every request:

```
Accept: application/json
X-XSRF-TOKEN: <COGNOS_XSRF>
X-Requested-With: XMLHttpRequest
Cookie: <COGNOS_COOKIE>
```

`discover-cognos.sh` walks `objects/{id}/items` breadth-first, recurses into
`folder`s, and fetches the spec for each `module` / `report` / `reportView` it
finds into `<out>/specs/`. It treats a 401/403 as token expiry: it sets
`token_expired: true` in `inventory.json` and stops gracefully (already-fetched
specs are kept, so a re-run after re-auth is resumable).

## What is NOT available here

- **Dashboards / explorations** expose a different spec format (not the report
  XML) — they're inventoried (counted, named) but not deep-scored in this MVP.
- **Per-report run / view counts** are not on this REST surface — see
  `usage-telemetry.md`.
- **Uploaded source files** (`.xlsx`) behind a `useSpec.type:"file"` module are
  stored as proprietary `.pq` and are not re-downloadable via REST.
