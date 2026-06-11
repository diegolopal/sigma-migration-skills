---
name: microstrategy-to-sigma
description: >-
  Migrate MicroStrategy (Strategy One) content to Sigma. Use when the user has
  MicroStrategy dossiers, reports, or a classic schema (attributes / facts /
  metrics) and wants to recreate them in Sigma. Extracts the dossier + full
  semantic model over the MSTR REST API into a bundle, converts it to a Sigma
  data model + workbook, reproduces Analytical-Engine row-collapse quirks
  deterministically, and verifies row-level parity. Live-validated with exact
  parity on the classic-schema grid path.
user-invocable: true
---

# MicroStrategy → Sigma migration

Extract a MicroStrategy **dossier + its full semantic model** into one
`bundle.json`, convert it to a Sigma **data model** (table sources + joins +
metrics) and a matching **workbook**, then **verify row-level parity** against
the numbers MicroStrategy itself reports. Translate what maps cleanly; **flag
what doesn't** (unmapped viz types → flagged tables) instead of emitting wrong
logic.

> **Validated**: exact parity (19/19 + 30/30 + 3/3 rows) on a live Strategy One
> trial against Snowflake — classic-schema path, grid reports, incl. a
> `Count<Distinct=True>` metric, a compound margin metric, and an
> Analytical-Engine row-collapse report. Chart-viz emission and the newer
> "Data Model" object are roadmap (`refs/design-notes.md`).

> Read `refs/` before relying on shapes: `mstr-rest-api.md` (every verified
> REST gotcha — changesets, locks, lowercase response headers, session-bound
> dossier flows), `ae-row-collapse.md` (the one MSTR behavior no clean SQL
> reproduces, and the pinning workflow), `viz-type-mapping.md` (dossier viz →
> Sigma element lookup), `design-notes.md` (architecture + modeling gotchas +
> roadmap). For canonical Sigma spec shapes, defer to the companion
> `sigma-data-models` / `sigma-workbooks` skills.

---

## Prerequisites

- **MicroStrategy REST access** — `MSTR_BASE_URL` (the Library root, e.g.
  `https://<host>/MicroStrategyLibrary`), `MSTR_USERNAME`, `MSTR_PASSWORD`
  (+ optional `MSTR_PROJECT_ID`), exported or in `~/.sigma-migration/env`.
  Auth is session-based (`POST /api/auth/login`, loginMode 1) — there is no
  API-key concept; `scripts/mstr.py` handles it.
- **Sigma API token** — `eval "$(scripts/get-token.sh)"` (uses
  `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`, same neutral-cred pattern as the
  sibling skills).
- **The same warehouse on both sides.** Sigma reads the warehouse live; parity
  only means something when the Sigma connection reaches the database
  MicroStrategy queries.
- **Python 3** (stdlib only; `resolve_ae_winners.py` and parity readback also
  want `PyYAML` for Sigma's YAML spec responses).

## Phase 0 — Discover

Run the sibling **`microstrategy-assessment`** skill for an estate-wide
inventory (reports/dossiers, viz histogram, complexity tags) — its
`inventory.json` lists dossier ids. Or quick-check connectivity and pick a
dossier by hand:

```bash
python3 scripts/mstr.py                          # login probe + project list
# dossiers: see assessment, or GET /api/searches/results?type=55 via mstr.py
```

## Phase 1 — Extract the bundle

```bash
python3 scripts/extract.py <dossierId> bundle.json
```

Walks dossier definition → dataset reports (`showExpressionAs=tokens`) →
referenced attributes / metrics (compound bases included via a second pass) /
facts / logical tables / hierarchy relationships. The bundle is the converter
contract — `fixtures/bundle.json` is a real, validated example.

## Phase 2 — Convert → Sigma specs

```bash
python3 scripts/convert.py --bundle bundle.json \
  --connection-id <SIGMA_CONNECTION_ID> --database <DB> --folder-id <FOLDER_ID> \
  [--inode-map inodes.json]        # physical table name -> inode tail, optional
```

Emits `sigma_dm_spec.json` (one table element per logical table, derived
left-outer joins, a consumable join element, token-parsed metrics with derived
display formats) + `sigma_workbook_spec.json` (one page per dossier chapter,
grouped tables mirroring each report template) + `parity_keys.json`. The
workbook spec carries `{{DATA_MODEL_ID}}` / element-id placeholders until
Phase 4 re-runs with real ids.

Conversion patterns to know (details in `refs/`): grids group by the
attribute's KEY form and label with `Max([DESC])`; dim-keyed groupings get an
`exclude [null]` filter to mirror MSTR's inner joins; metrics referencing
metrics are inlined in workbook context, `[Name]`-referenced in DM context.

## Phase 2.5 — AE row-collapse resolution (only when flagged)

If any report has an attribute whose DESC form differs from its key (the
converter's grouping output makes this visible — and `resolve_ae_winners.py`
detects it itself), MicroStrategy's Analytical Engine collapses non-unique key
groups to one representative row that **cannot be derived from the model**:

```bash
eval "$(scripts/get-token.sh)"
python3 scripts/resolve_ae_winners.py --connection-id <id> --database <DB> \
  --folder-id <folderId> --out ae_winners.json
python3 scripts/convert.py ... --ae-winners ae_winners.json
```

It re-executes the affected reports in MSTR, computes the clean warehouse
groups via a throwaway Sigma probe workbook, pins each winner empirically, and
the converter emits a deterministic SQL element reproducing the grid. Read
`refs/ae-row-collapse.md` — this is the single biggest parity trap.

## Phase 3 — POST the data model + read back ids (hard gate)

```bash
eval "$(scripts/get-token.sh)"
curl -s -X POST "$SIGMA_BASE_URL/v2/dataModels/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Content-Type: application/json" \
  -d @sigma_dm_spec.json            # -> dataModelId
curl -s "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" > dm_readback.yaml
```

The readback is **YAML**, with **reassigned element ids** — capture them as
`dm_element_ids.json` (`{"<element name>": "<server id>"}`). **Gate:** scan the
readback for any column with `type: error` (a spec can POST 200 yet carry
formulas that don't resolve at query time). Do not proceed on errors —
`mcp__sigma-data-model__diagnose_sigma_save_error` and the
`sigma-data-models` skill are the debugging path.

## Phase 4 — Re-emit the workbook with real ids, POST it

```bash
python3 scripts/convert.py ... --data-model-id <dataModelId> \
  --dm-element-ids dm_element_ids.json [--ae-winners ae_winners.json]
curl -s -X POST "$SIGMA_BASE_URL/v2/workbooks/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Content-Type: application/json" \
  -d @sigma_workbook_spec.json      # -> workbookId
```

Read the workbook spec back the same way and confirm no `type: error` columns.
(Workbook DELETE, if you need to retry, is `DELETE /v2/files/<id>` — not
`/v2/workbooks/<id>`.)

## Phase 5 — Verify parity (hard gate — the real proof)

Expected values come **from MicroStrategy, never invented**: execute each
report via `POST /api/v2/reports/{id}/instances?limit=N` and write
`expected_parity.json` (`{"<report name>": [{"keys": [...], "values": {...}}]}`
— `fixtures/expected_parity.json` is the shape). Then:

```bash
python3 scripts/verify_parity.py --workbook-id <workbookId> \
  --expected expected_parity.json --report parity_report.md
```

Exports every workbook element to CSV via the Sigma export API and compares
row-by-row (money/counts exact; ratio metrics rel 1e-6). **GREEN only when
every report PASSes** — never on a 200 POST alone. Mind freshness: Sigma reads
the live warehouse; if rows landed since the MSTR numbers were captured,
re-capture before calling a delta a failure.

---

## What converts, what's flagged (never faked)

**Converted (live-validated):** classic schema → DM (logical tables → table
elements; attribute key forms on fact+lookup → left-outer joins; heterogeneous
key columns; facts + token-parsed metrics incl. `Count<Distinct=True>` →
`CountDistinct` and compound metrics; semantic display formats) · dossier
chapters → workbook pages with grouped tables (KEY-form grouping + `Max(DESC)`
labels + null-exclude filters) · AE row-collapse reports → deterministic
pinned-winner SQL elements.

**Flagged / roadmap:** unmapped viz types → flagged table fallback
(`refs/viz-type-mapping.md`); chart emission (kpi/bar/line/combo) extraction-
validated but build roadmap; filters/selectors/page-by/prompts; the newer
REST-authorable "Data Model" object incl. `securityFilters` (the future RLS
port surface — until then, **ask the customer about security filters
explicitly**; never assume an estate has none just because the classic extract
doesn't carry them).

## Gotchas baked into the scripts (don't re-learn these)

- Changeset lock dangling + `DELETE /api/model/schema/lock`; reports do NOT
  use changesets; lowercase `x-mstr-ms-instance` response header; PUT
  relationships REPLACES the parent list — `refs/mstr-rest-api.md`.
- Attribute-count metrics (`Count(Customer)`) → cartesian governance aborts —
  count a fact/key column instead; compound denominators need `ZeroToNull()`
  or Snowflake kills the report — `refs/design-notes.md`.
- Python 3.13+ rejects some MSTR cloud CA certs (`VERIFY_X509_STRICT`) —
  `mstr.py` handles it.
