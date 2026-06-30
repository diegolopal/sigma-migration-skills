---
name: gooddata-assessment
description: >-
  Take inventory of a GoodData Cloud / GoodData.CN estate and produce a
  migration-readiness readout — workspace, dataset, metric, insight, and
  dashboard counts; a MAQL-complexity histogram (which metrics use BY / WITHIN /
  BY ALL / FOR time transforms); an insight visualization-type mix; and per-
  dashboard AUTO / HINT / MANUAL / UNHANDLED tags scored against the
  gooddata-to-sigma converter's actual coverage. Use when a user wants to scope
  a GoodData→Sigma migration, audit estate sprawl, or pick which dashboards to
  convert first. Read-only, all-free pre-scoping over the declarative workspace
  export.
user-invocable: true
---

# GoodData assessment

Read-only migration-readiness readout for a GoodData Cloud / .CN estate. Pulls
the declarative layout (no writes) and scores it against what
`gooddata-to-sigma` can actually convert.

> Status: working + live-validated. `scripts/assess.py` reuses the converter's
> own MAQL translator for honest coverage scoring (no guessing) and tags each
> dashboard AUTO / HINT / MANUAL / UNHANDLED.

## What it reports

- **Inventory** — workspaces, datasets, metrics, insights, dashboards.
- **MAQL complexity** — histogram of metrics by construct (plain agg / `WHERE` /
  `BY`-`WITHIN`-`BY ALL` context / `FOR` time transforms / ranking), since
  context + time intel are the conversion-risk drivers (`maql-mapping.md`).
- **Visualization mix** — insight `visualizationUrl` histogram, with each type
  tagged against `viz-type-mapping.md` (auto-mappable vs flagged).
- **Per-dashboard tag** — AUTO (fully mappable), HINT (minor manual), MANUAL
  (context MAQL / RLS review), UNHANDLED (exotic widgets / compute-only metrics).
- **Shortlist** — value/cost-ranked migration order.

## Usage

```bash
eval "$(../gooddata-to-sigma/scripts/get-token.sh)"
python3 scripts/assess.py --workspace <id>     # or --all
```

Usage telemetry (per-dashboard view counts) is the universal weak spot — it is
not in the declarative model; note it as a manual input if needed.
