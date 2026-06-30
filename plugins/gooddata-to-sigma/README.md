# gooddata-to-sigma

Claude Code plugin for migrating **GoodData Cloud** / **GoodData.CN** to
**Sigma**, in the same format and phase structure as the
[sigma-migration-skills](https://github.com/twells89/sigma-migration-skills)
converters (Tableau, Power BI, Qlik, ThoughtSpot, QuickSight, Cognos,
MicroStrategy, SSRS). Built standalone so it can graduate into that
marketplace's `plugins/`.

## Status: LIVE-VALIDATED — exact parity (data model + workbook)

Proven end-to-end on a GoodData Cloud trial → Sigma, both on Snowflake: a
workspace (LDM + 6 MAQL metrics + 5 insights + a dashboard) migrated to a Sigma
**data model** (5/6 metrics translated, exact parity — Net Revenue 117,040.63,
Orders 696, AOV 168.16; the `BY ALL` share metric correctly **flagged**) and a
Sigma **workbook** (KPIs + bar charts; the by-region breakdown exact via the
migrated relationship). MAQL coverage on that workspace: 5 AUTO / 1 CONTEXT / 0
unhandled. Remaining: live FOR-PREVIOUS date-intel (translator routes it to a
workbook DateLookback; not yet exercised on a live date dimension).

The migration design is grounded in a verified read of GoodData's current
public docs (June 2026). The spike findings live in
[`skills/gooddata-to-sigma/refs/`](skills/gooddata-to-sigma/refs/):

- [`gooddata-api.md`](skills/gooddata-to-sigma/refs/gooddata-api.md) — the
  declarative REST API (workspace layout export), auth, and the LDM + analytics
  model JSON structure.
- [`maql-mapping.md`](skills/gooddata-to-sigma/refs/maql-mapping.md) — MAQL
  metric grammar → Sigma formula mapping, and the constructs we expect to flag.
- [`viz-type-mapping.md`](skills/gooddata-to-sigma/refs/viz-type-mapping.md) —
  insight (`visualizationObject`) bucket/`visualizationUrl` → Sigma element.
- [`design-notes.md`](skills/gooddata-to-sigma/refs/design-notes.md) —
  end-to-end architecture, parity strategy, RLS, risks, and build order.

`scripts/discover.py` is a functional declarative-export client (auth +
workspace layout pull) but has **not been run against a live workspace yet** —
the first build step is a GoodData Cloud trial signup to validate auth +
discovery, then a real fixture, exactly as the ThoughtSpot / Sisense skills were
bootstrapped.

## Why GoodData is tractable

Unlike screen-scraped sources, GoodData exposes the **entire workspace
declaratively**: one `GET /api/v1/layout/workspaces/{id}` returns the logical
data model *and* the analytics model (metrics, insights, dashboards) as JSON.
GoodData Cloud computes on a customer warehouse (Snowflake / BigQuery /
Redshift / …) via a data-source mapping, so Sigma can point at the **same
warehouse** for exact parity — the same playbook as every other converter.

## The two skills

- **`gooddata-to-sigma`** — the converter: discover → data model → workbook →
  parity. Translates what maps cleanly (datasets, references, most MAQL,
  standard insights, dashboard layout, user data filters) and **flags** what
  doesn't (compute-engine-only metrics, exotic MAQL context, unsupported
  widgets) rather than emitting wrong logic.
- **`gooddata-assessment`** — read-only estate inventory + migration-readiness
  readout (workspace/metric/insight/dashboard counts, MAQL-complexity histogram,
  per-dashboard AUTO / HINT / MANUAL / UNHANDLED scoring against the converter's
  coverage).

## Scope

GoodData **Cloud / .CN first** (clean declarative API, `/api/v1`). Legacy
**GoodData Platform** (the `/gdc/md/{project}` "classic" API, MUF user filters)
is a documented fast-follow, not the initial target — see `design-notes.md`.

## License

MIT.
