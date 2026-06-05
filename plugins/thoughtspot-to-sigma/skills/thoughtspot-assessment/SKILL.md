---
name: thoughtspot-assessment
description: Take inventory of a ThoughtSpot instance and produce a migration-readiness readout — models/worksheets, Liveboards, Answers, connections, per-Liveboard chart-type mix and complexity, chart-type coverage, and a value/cost-ranked migration shortlist. Use to scope a ThoughtSpot→Sigma migration or audit BI sprawl. Read-only.
---

# ThoughtSpot migration assessment

Read-only pre-scoping for a ThoughtSpot → Sigma migration. Complements
`thoughtspot-to-sigma` (which does the actual conversion).

## Auth
Same as `thoughtspot-to-sigma`: `TS_HOST` + `TS_TOKEN` (SSO session token or
Trusted-Auth service token). No Sigma credentials needed — this only reads
ThoughtSpot.

## Run
`scripts/scan.py` — inventories the instance via `metadata/search`
(LOGICAL_TABLE / LIVEBOARD / ANSWER / CONNECTION), exports each Liveboard's TML,
and per Liveboard scores migration complexity from its visualizations:
viz count + distinct chart kinds + models touched. Output:
- inventory counts
- how many Liveboards are readable via the API (system/sample objects are
  export-FORBIDDEN and not migratable by a normal identity)
- a migration shortlist, easiest first, flagging unsupported chart types
- overall chart-type coverage % across all exportable visualizations
- the set of models the Liveboards depend on (migrate these first)

Writes the full report to `~/thoughtspot-migration/assessment.json`.

## Chart-type coverage
The `thoughtspot-to-sigma` pipeline maps KPI / COLUMN / BAR / LINE / PIE / TABLE
/ ADVANCED_COLUMN / stacked / area / LINE_COLUMN to Sigma equivalents. Flagged
for review (no direct 1:1 in the current pipeline): SCATTER, BUBBLE, GEO_AREA,
PIVOT_TABLE, WATERFALL, FUNNEL, TREEMAP, LINE_STACKED_COLUMN.

## Notes
- TML export embeds raw control chars in JSON → `json.loads(..., strict=False)`.
- ThoughtSpot TML uses bare `=` (`oper: =`) which trips PyYAML's value tag — the
  scan registers a constructor that reads it as a string.
- Validated on a trial: 32 Liveboards / 27 models / 451 viz → 90.5% chart-type
  coverage; the 12 migration fixtures ranked easiest, system dashboards hardest.
