# gap-scout subagent — guide for the main agent (Qlik → Sigma)

When discovery / `convert_qlik_to_sigma` flags an **unhandled** Qlik expression (or a
high-volume one worth automating), spawn a separate subagent — the "gap scout" — to find
a Sigma translation that actually works against the customer's live Sigma site, then
persist it so future conversions apply it automatically.

The scout writes validated translations to `~/.qlik-to-sigma/learned-rules.yaml` (customer
HOME, **not** the skill repo, so `git pull` never clobbers them). `scripts/learned-rules.py`
loads them; the build step applies them before falling back to a WARN.

## When to spawn

After discovery, for each Qlik expression the converter omits/flags as unhandled — these
are the `qlikExprToSigma` warning cases:

| Qlik pattern | Why flagged | Candidate Sigma translation to try |
|---|---|---|
| `Aggr(<agg>, <dim>)` | nested-aggregate, no 1:1 | a **grouped/level element** or a pre-aggregated DM element; sometimes `WindowSum`/`WindowAvg` over a partition |
| `RangeSum/RangeAvg/RangeMin/RangeMax(...)` | row-wise range agg | `Sum(...)`/`Avg(...)` if it's really an aggregate; else explicit arithmetic |
| `Class(<field>, <size>)` | binning | `If()` range buckets, or `Floor([x]/n)*n` |
| `Dual(text, num)` | dual text/number | keep the numeric part; surface text via a separate label column |
| `GetSelectedCount / GetFieldSelections / GetCurrentSelections` | selection state | no Sigma equivalent — usually a control-driven measure; escalate |
| Set Analysis `Sum({<F={v}>} X)` | (handled) | `SumIf([X], [F]=v)` — already validated; only scout exotic set modifiers |

Spawn ONE scout per distinct pattern; run them in parallel — they're independent.

## How to spawn (from the main agent)

Use the Agent tool, `subagent_type: 'general-purpose'`. Self-contained prompt:

```
You are a translation scout for a Qlik→Sigma migration. Propose a Sigma formula that
replaces a Qlik expression, validate it against the live Sigma API, and persist the rule.

INPUTS
- Qlik feature/pattern: <e.g. "RangeAvg">
- Sample expressions from the app: <2-5 real examples>
- Sigma data-model id: <dm-id>
- Sigma denormalized element id: <element-id>   (the master that holds all fields)
- Sigma folder id: <folder-id>

PROCEDURE
1. Read refs/sigma-build-gotchas.md (function context rules: *Over window fns error in
   grouping-table calc cols; tables aggregate via groupings; etc.).
2. Propose ONE candidate Sigma formula. Reference columns as [Master/<Display Name>].
   Prefer Sigma whitelist functions (SumIf/CountIf, Avg, WindowSum/WindowAvg, If, etc.).
3. Validate + persist in one call:
     eval "$(scripts/vendor/get-token.sh)"   # sets SIGMA_API_TOKEN
     python3 scripts/scout-validate.py \
       --formula '<candidate with REAL [Master/Col] names>' \
       --feature '<feature>' \
       --pattern '<Qlik regex; capture groups for column refs>' \
       --template '<Sigma template using \1, \2 for captures>' \
       --hint '<post-publish caveat>' \
       --description '<one-line>' --example-from '<app/measure>' \
       --data-model-id <dm-id> --element-id <element-id> --folder-id <folder-id> \
       --home ~/.qlik-to-sigma   [--kind table]   # default kpi-chart; use table for row-level/dimension formulas
4. Parse the JSON:
   - status=validated → rule is now in the local YAML; done.
   - status=error     → try a different candidate (≤3 attempts), then escalate
                        (note it as a manual WARN for post-publish handling).

OUTPUT
One paragraph: feature, candidate, status, and (for cleanup) note the test workbook is
auto-deleted by the validator.
```

## What the scout depends on

- `scripts/scout-validate.py` — builds a throwaway test workbook (Master from the DM
  element + a column using the candidate), checks `/v2/workbooks/{id}/elements/{el}/columns`
  for `type=="error"`, persists to the local YAML on success, deletes the test workbook.
- `scripts/learned-rules.py` — the loader the build step uses (`load()` + `apply()`).

## File locations (CRITICAL)

| File | Path | Why |
|---|---|---|
| Learned rules | `~/.qlik-to-sigma/learned-rules.yaml` | Customer home; `git pull` can't clobber |
| Override (CI/sandbox) | `$QLIK_TO_SIGMA_HOME` | points the loader + validator elsewhere |

Keep `.qlik-to-sigma/` out of the skill repo (`.gitignore`).

## Why a separate subagent

- **Context isolation** — each Sigma POST/readback is verbose; keep the validation loop out of the main conversion's context (matters for batch/tenant migrations).
- **Bounded budget** — ≤3 attempts per gap; a failure doesn't block the migration, it just stays a WARN for manual handling.
- **Compounds** — every validated rule persists locally and auto-applies to the next app; promising rules can later be promoted into the converter itself.
