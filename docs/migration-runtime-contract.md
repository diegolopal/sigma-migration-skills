# Migration Runtime Contract

**Status:** proposed · **Owner:** tj@sigmacomputing.com · **Date:** 2026-06-26

## Problem

When customers run the migration skills themselves, behavior diverges at the **seams** —
how input comes in, how the Sigma connection is resolved, and how a run ends. The
conversion cores are well-tested; the seams are prose in each `SKILL.md`, so every
customer's agent improvises differently. Observed failures:

- **Inconsistent input.** Customers drop a raw export (`.twb`/`.pbix`) instead of using the
  live source API. The cold-discovery path assumes live source access and degrades badly.
- **Token waste on connection resolution.** The agent free-searches Sigma for the
  connection that should back the data model, burning tokens on every run.
- **Silent completion.** Telemetry (`sigma_telemetry.py` → Render) is documented as an
  optional manual step, not wired into the orchestrators. PowerBI never fires it; a run can
  "finish" without the agent prompting to send the signal.

These are one root cause — unstandardized seams — not three bugs. Fix: a shared **runtime
contract** of three bookend components, rolled out like the gap-scout (PR #153) and
coverage (PR #177) gates.

## Current-state facts (grounding)

- **Telemetry already exists and works.** `shared/lib/sigma_telemetry.py` POSTs
  `migration_complete` to `https://sigma-migration-telemetry.onrender.com/track`
  (payload: `tool`, `sigma_region`, `org_id_hash` = SHA256(client_id)[:8], `duration_seconds`,
  `success`, `skill_version`). Fanned out to 9 plugins via `shared/manifest.json`. CLI wrapper:
  `shared/scripts/report-telemetry.py`. **Gap is wiring, not feature** — it's an optional
  agent step; `migrate-powerbi.rb` has zero telemetry calls.
- **Completion hard-gate already exists.** `shared/scripts/assert-phase6-ran.rb` (8 sub-gates)
  is the canonical end-of-run gate, fanned out to 6 plugins, auto-run on
  `migrate-tableau.rb --finalize`. Escape hatches require a named reason.
- **Two rollout patterns:** byte-identical via `shared/manifest.json` + `tools/sync-shared.rb`
  (CoverageGate), or per-plugin native-language variants (ScoutGate). Telemetry & the gate
  use the byte-identical pattern.
- **Fanout mismatch:** telemetry → 9 plugins; hard-gate → 6 (missing **qlik, cognos, gooddata**).

## The contract

### ① Intake front-door (shared)
Runs first in every migration skill.
- **Detect input mode:** `live` (source API + creds) · `file` (raw export only) · `both`.
- **Resolve the Sigma connection ONCE.** Prompt the user or read config; list connections a
  single time; cache to `run-dir/connection.json`. All downstream steps read that file —
  no free-searching. Shared `resolve-connection` helper (all converters need it).
- **Record run-start timestamp** to `run-dir/intake.json` → feeds telemetry `duration_seconds`.
- **Print an expectations banner** per mode.

### ② Raw-mode = build + warehouse self-verify
When the **source tool** is unreachable but Sigma/warehouse is live (the common
"customer dropped a `.twb`" case):
- Build DM + workbook from the export file (the XML is rich: calcs, chart specs, filters, layout).
- **Repoint verification** to the live **Sigma warehouse** connection, not the source tool.
  Real numbers; no diff against the source's rendered output.
- Skip source-side PNG/CSV diff in Phase 6; keep the warehouse-side sanity check.
- Banner: *"verified against warehouse — NOT against live <SourceTool>."*
- `assert-phase6-ran.rb` learns a `mode` flag so it accepts warehouse-verified parity instead
  of hard-failing on missing source-side artifacts.

### ③ Completion gate (shared)
Wire the **existing** telemetry into the finalize path + enforce it.
- Fire `sigma_telemetry` in the orchestrator finalize path on **both success and failure**
  (so it cannot sit behind a passing parity gate).
- Add **Gate 9** to `assert-phase6-ran.rb`: verify a `run-dir/telemetry-sent.json` marker
  exists. Agent can't declare GREEN without it. Escape hatch `--skip-telemetry-gate <reason>`.
- Print the standardized handoff / next-steps.

## Rollout (3 PRs, each lands independently)

1. **Completion gate** — wire existing telemetry into every orchestrator finalize path +
   add Gate 9. Duration from run-dir mtimes until ① lands. Fixes the PowerBI miss. Smallest,
   lowest risk, proves the mechanic.
2. **Intake + `resolve-connection` cache** — biggest token + bad-conversion win; records
   run-start so duration tracking gets clean.
3. **Raw-mode warehouse-verify** — depends on ①'s mode detection; goes last.

## Resolved decisions (2026-06-26)

- **D1 — gate fanout → extend to all 9.** Add qlik/cognos/gooddata to the
  `assert-phase6-ran.rb` fanout so telemetry (Gate 9) is enforced on every plugin. No plugin
  can finish silently.
- **D2 — connection resolution → config-first, prompt on miss.** Intake reads
  `~/.sigma-migration/config` first; prompts only when no connection is cached/configured.
  Zero tokens on repeat runs.
- **D3 — telemetry payload → add `mode` enum.** Record `mode: live|file|both` (no PII) so we
  can measure how often customers run file-only — the path that degrades — and target
  investment.
