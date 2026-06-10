---
name: quicksight-to-sigma
description: Convert an Amazon QuickSight analysis or dashboard into a Sigma data model and matching dashboard. Use when the user has a QuickSight analysis/dashboard and wants to recreate it in Sigma. Covers AWS-CLI extraction of the analysis definition + datasets + data sources, calc-field / data-prep translation via the convert_quicksight_to_sigma MCP, posting the data model + workbook via the Sigma REST API, layout, and parity verification against the same warehouse.
---

# QuickSight → Sigma

> Status: **foundation** (converter MCP + browser shipped 2026-05-28).
> Beads: converter = `beads-sigma-j5e`; CustomSql/DIRECT_QUERY fixup = `beads-sigma-vy4k`.
> Defers to: `sigma-workbooks` (canonical workbook spec), `sigma-data-models` (DM spec), the `convert_quicksight_to_sigma` MCP tool, and the shared vendor-neutral Sigma-side scripts (`post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `verify-parity.rb`) reused across the migration skills.

## What's proven (the happy path)
```
1. AUTH      AWS CLI → QuickSight (Enterprise edition REQUIRED); Sigma creds via get-token.sh
2. DISCOVER  describe-analysis-definition + describe-data-set(s) + describe-data-source(s)  → quicksight-discover.py → signals.json
3. CONVERT   convert_quicksight_to_sigma MCP (analysis.json + dataset jsons + connectionId)  → Sigma DM JSON      [MCP gate]
4. POST DM   fixup (name elements + passthrough cols, rewrite sql refs, schemaVersion=1) → validate → POST /v2/dataModels/spec
5. WORKBOOK  master tables per DM element + chart elements mirroring the QS visuals → POST /v2/workbooks/spec
6. LAYOUT    QS grid x,y,w,h → 24-col layout XML → put-layout.rb
7. VERIFY    sigma-mcp-v2 query each element returns real rows; Phase 6 parity vs the QuickSight aggregation    [hard gate]
```

See `refs/migration-test-slate.md` for the complexity taxonomy + 20-dashboard test slate that grounds the converter's coverage and known gaps.

## Phase 1 — Auth

**QuickSight (AWS CLI).**
- The `describe-analysis-definition`, `describe-dashboard-definition`, and `describe-data-set` APIs are **Enterprise-edition only**. A Standard-edition account rejects them — there is no extraction path on Standard. Confirm the edition first.
- QuickSight's **identity region is often `us-east-1`** even when the data lives elsewhere; the analysis/dataset/data-source resources are read from the identity region. Pass `--region us-east-1` unless you know the account is regionalized differently.
- Auth is whatever the AWS CLI is already configured with: a named `--profile`, SSO (`aws sso login`), or — for Okta-fronted orgs — `gimme-aws-creds` writing a profile. The discovery script just shells out to `aws quicksight ...`.
- You need the account id (`aws sts get-caller-identity`) and the analysis (or dashboard) id.

**Sigma.** Same as the other migration skills: `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` → `scripts/get-token.sh` exchanges them for a `SIGMA_API_TOKEN`. You also need a **Sigma connection** that reaches the same warehouse the QuickSight datasets query (its `connection_id` feeds the converter), and a target **folder id**.

## Phase 2 — Discover

```bash
python3 scripts/quicksight-discover.py \
  --account-id <ACCOUNT_ID> --region <REGION> --profile <PROFILE> \
  --analysis-id <ANALYSIS_ID> \
  --out-dir ~/quicksight-migration/<name>
# (or --dashboard-id <DASHBOARD_ID> instead of --analysis-id)
```

Pulls `describe-analysis-definition` (or `-dashboard-definition`) + `describe-data-set` for every `DataSetIdentifierDeclarations` entry + `describe-data-source` for each referenced source, and writes into the out-dir:
- `analysis.json` — the full describe-*-definition response (the converter's primary input).
- `datasets/<id>.json` — one per dataset (PhysicalTableMap, LogicalTableMap/transforms, calc fields, output columns).
- `datasources/<id>.json` — one per source (the `Type` tells you Snowflake / Redshift / Athena / S3 / SaaS).
- `signals.json` — normalized: per-sheet visuals (type + VisualId + title + referenced ColumnNames), calc fields, parameters, datasets, sources. Drives the convert + workbook + layout phases.

## Phase 3 — Convert (MCP gate)

```bash
ruby scripts/convert-model.rb --emit-mcp \
  --discover-dir ~/quicksight-migration/<name> \
  --connection-id <SIGMA_CONNECTION_ID> \
  [--database <DB> --schema <SCHEMA>]
```

This prints the exact `convert_quicksight_to_sigma` MCP-tool call — `files` = `analysis.json` + each `datasets/*.json`, plus `connection_id` (and `database`/`schema` overrides if a dataset's source path is incomplete). **The agent then runs that MCP tool** and saves the returned Sigma data-model JSON (e.g. `converter-out.json`).

What the converter handles vs. what it doesn't (see `refs/migration-test-slate.md` for the full taxonomy):
- **Handled**: RelationalTable, CustomSql, JoinInstruction, DataTransforms (CreateColumns/Rename/Cast/Filter/Project), ~40 calc-field functions (`ifelse`→`If`, `switch`→nested `If`), parameters → Sigma controls. KPI / bar / line / donut/pie visuals on the workbook side.
- **Gaps (degrade to `/* TODO */` placeholder or skipped)**: window / table-calc functions (`sumOver`, `runningSum`, `rank`, `percentOfTotal`, `periodOverPeriod*`, `window*`, `percentile*Over`); S3Source & SaaSTable physical sources; analysis-level FilterGroups; ColumnConfigurations (formatting); dataset-of-datasets. Un-migratable visuals (Insight ML, CustomContent, Plugin, Sankey, map family) → emit a partial migration + warning manifest; never call these "failed".

For an untranslated calc-field expression, spawn the **gap-scout subagent** (see `scripts/gap-scout.md`): it proposes a Sigma formula, validates it against the live DM via `scripts/scout-validate-and-persist.rb`, and on success persists a rule to `~/.quicksight-to-sigma/learned-rules.yaml` (customer home — `git pull` can't clobber; the build script auto-applies it next run via `LearnedRules.load`). On failure the scout returns an **opt-in** `escalate-gap.py` command — filing a tracking issue is never automatic: run the returned `escalation.dry_run_cmd` to draft the issue (shows target repo + dedupe), show the user, and only re-run with `--yes` if they accept. Calc-field gaps route to the converter repos (`sigma-data-model-manager` + `sigma-data-model-mcp`, mirrored) with a cross-linked bead.

## Phase 4 — Fixup + POST the data model

The converter output needs fixups before `POST /v2/dataModels/spec` (gap `beads-sigma-vy4k`: CustomSql / DIRECT_QUERY elements come back nameless, and sql refs need rewriting):

```bash
ruby scripts/convert-model.rb --fixup \
  --in converter-out.json \
  --discover-dir ~/quicksight-migration/<name> \
  --folder-id <FOLDER_ID> \
  --out dm-spec.json
ruby scripts/validate-spec.rb --type datamodel dm-spec.json
ruby scripts/post-and-readback.rb --type datamodel --spec dm-spec.json --out dm-readback.json
```

`--fixup` forces `schemaVersion: 1`, names every element + its passthrough columns (so workbook masters can reference them), rewrites sql refs to `[Custom SQL/<ALIAS>]` form, and injects `folderId`. `post-and-readback.rb` confirms every column resolved to a concrete type — **no `error` columns**.

## Phase 5 — Build the workbook

```bash
ruby scripts/build-workbook-from-quicksight.rb \
  --analysis ~/quicksight-migration/<name>/analysis.json \
  --dm-readback dm-readback.json \
  --folder-id <FOLDER_ID> \
  --out wb-spec.json
ruby scripts/post-and-readback.rb --type workbook --spec wb-spec.json --out wb-readback.json
```

Mirrors the QuickSight visuals as Sigma elements off Data-page master tables, and emits a `wb-spec.map.json` (visualId → element-id) the layout phase consumes. Element shapes:
- Workbook element column refs use **`[<source element name>/<col>]`** (the source element name comes from the DM element name set in Phase 4).
- bar/line: `xAxis:{columnId}`, `yAxis:{columnIds:[...]}`.
- **pie/donut: `color:{id}` + `value:{id}`** (NOT xAxis/yAxis).
- KPI: a single measure formula wrapping the master column.

## Phase 6 — Layout (do NOT skip — stacked ≠ done)

```bash
ruby scripts/build-quicksight-layout.rb \
  --analysis ~/quicksight-migration/<name>/analysis.json \
  --map wb-spec.map.json \
  --out layout.xml
ruby scripts/put-layout.rb --workbook <WORKBOOK_ID> --layout layout.xml
```

Maps each QuickSight visual's grid cell → a 24-col Sigma layout. **QuickSight grid lines are 1-based** — `ColumnIndex`/`RowIndex` start at 1, so subtract 1 before scaling to the 0-based Sigma grid. Free-form / section-based QS layouts are approximated to the grid.

## Phase 7 — Parity (hard gate)

```bash
ruby scripts/phase6-parity-quicksight.rb --finalize --workbook <WORKBOOK_ID> ...
ruby scripts/assert-phase6-ran.rb        # hard gate — must pass before declaring GREEN
```

**POST success ≠ working.** You MUST query-verify the built elements:
- `sigma-mcp-v2 query` each element → confirm real rows (not blank / not all `error`).
- True parity: compare each Sigma aggregation against the same aggregation computed from the QuickSight side (or the warehouse). `assert-phase6-ran.rb` is a hard gate — a subagent must run it and it must pass before reporting success.

## Gotchas (carry these forward)
- **Enterprise edition is mandatory** for the `describe-*-definition` APIs. Standard rejects them outright — there's no fallback extraction.
- **QuickSight identity region is usually `us-east-1`** — resources read from the identity region, not the data region.
- **CustomSql / DIRECT_QUERY converter gap (`beads-sigma-vy4k`)**: those elements come back nameless and with raw sql refs; the `--fixup` step names them + rewrites refs to `[Custom SQL/<ALIAS>]`. Don't post the converter output unfixed.
- **Workbook element refs** are `[<source element name>/<col>]`, where the source element name is the DM element name set during fixup.
- **pie/donut** use `color:{id}` + `value:{id}`, not the bar/line `xAxis`/`yAxis` shape.
- **Layout grid is 1-based** in QuickSight — offset by 1 before scaling to Sigma's grid.
- **Window/table-calc functions are a known gap** — they degrade to a `/* TODO */` placeholder; verify the graceful degradation rather than treating it as a failure, and surface it in the migration warning manifest.

## Reuse, don't reinvent
These vendor-agnostic Sigma-side scripts are reused across the migration skills: `get-token.sh`, `lib/sigma_rest.rb`, `post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `validate-spec.rb`, `verify-parity.rb`, `cleanup-orphan-workbooks.rb`. Only the QuickSight-specific stages (`quicksight-discover.py`, `convert-model.rb`, `build-workbook-from-quicksight.rb`, `build-quicksight-layout.rb`, `phase6-parity-quicksight.rb`) are new.


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_quicksight_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for QuickSight:** `RowLevelPermissionTagConfiguration` (tag-based RLS to a user-attribute), `ColumnLevelPermissionRules` (to CLS). A `RowLevelPermissionDataSet` is flagged (its grant rows live in a separate dataset not in the export — recreate as a user attribute).

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

