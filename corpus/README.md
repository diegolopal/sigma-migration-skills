# Regression Corpus

Real source-tool artifacts + golden converter outputs + a runner, so converter
and builder changes can be smoke-tested **without live tenants**. Everything
here is demo/synthetic data (CSA.TJ retail star, synthetic workforce, GO
Sales) — no tokens, no customer names.

```
corpus/
  run-corpus.sh           # the runner (see below)
  lib/corpus_check.py     # normalize / summarize / check / diff helper
  lib/mcp_convert.py      # call the hosted sigma-data-model MCP server over HTTP
  <tool>/<case-name>/
    MANIFEST.md           # what it is, features exercised, converter call,
                          # parity refs, and a ```json expectations block
    <artifact files>      # source-tool inputs (or referenced from a plugin's
                          # fixtures/ dir by relative path — never duplicated)
    golden/*.json         # converter output, id-NORMALIZED (see below)
```

## Cases

| Case | Source format | Golden |
|---|---|---|
| tableau/orders-overview | .twb workbook + discovery signals | data model (9 elements, LOD child) |
| tableau/structural-workarounds | synthetic .twb (story + blend + nested LOD/ISOYEAR/FINDNTH/bins) | skill-script pins: story-plan / blend-plan / lod-chains (no golden DM) |
| powerbi/model-fixtures | 8 TMSL .bim (plugin fixtures) | DM for fixture_01 |
| powerbi/report-classic-employee-dashboard | legacy single report.json | artifact-pin only |
| powerbi/report-pbir-retail-performance | exploded PBIR + bookmarks | artifact-pin only |
| qlik/exec-overview-smoke | Engine/REST tables + master measures | DM (11 elements, Set Analysis) |
| thoughtspot/retail-analytics | model + liveboard TML | DM (7 elements, formulas) |
| quicksight/orders-overview | analysis + dataset describe JSON (plugin fixtures) | DM (CustomSql element) |
| cognos/great-outdoors-module | Data Module JSON (plugin fixtures) | DM (25 elements) |
| cognos/sales-overview-charts-report | report-spec XML (plugin fixtures) | workbook (17 elements) |
| looker/skilltest-orders | LookML model+views+dashboard (plugin fixtures) | DM (explore + join) |

## Runner

```
./run-corpus.sh --check              # CI-safe: artifacts exist & parse; golden
                                     # structure matches MANIFEST expectations
./run-corpus.sh --check qlik         # one tool only
./run-corpus.sh --reconvert          # prints each case's exact converter call
./run-corpus.sh --diff <case> --converted fresh.json   # byte-diff vs golden
```

`--check` needs only python3 stdlib (PyYAML optional) — runnable in plain CI
with no creds.

## Goldens are id-normalized

The converters generate random element/column ids on every run
(`inode-<rand>/COL`, 10-char ids). Goldens are stored after
`lib/corpus_check.py normalize`, which rewrites every id to a stable
positional token (`id0001`, `inode-NORM0003/CUSTOMER_KEY`) in first-seen
order. A reconverted output, normalized the same way, **byte-diffs clean**
against the golden when the converter behavior is unchanged (verified for
lookml on 2026-06-10). Normalization is idempotent.

Goldens keep the full converter envelope — `{sigmaDataModel|workbook, stats,
warnings}` — so warning-text regressions are caught too.

## Adding a case

1. `mkdir corpus/<tool>/<case>/`; drop artifacts in (or reference a plugin's
   `fixtures/` file by relative path — keep plugin fixtures where they are).
   Verify: demo/synthetic data only, no tokens, sanitize tenant object ids
   (e.g. PBI `semanticmodelid`).
2. Run the converter (the matching `mcp__sigma-data-model__convert_*` tool, or
   the in-repo cognos converter via `npm run convert`). Save the FULL result
   JSON (including stats + warnings).
3. `python3 lib/corpus_check.py normalize raw.json corpus/<tool>/<case>/golden/data-model.json`
4. `python3 lib/corpus_check.py summarize golden/...` and copy the counts into
   a `## Expectations` ```json block in `MANIFEST.md` (see any existing case):
   `artifacts` (paths relative to the case dir) + `goldens` (per-file counts
   and optional `element_names` / `metric_names` / `relationship_names`).
5. `./run-corpus.sh --check <tool>` must pass.

Large artifacts: the hosted MCP server rejects bodies over ~100 KB (HTTP 413).
For those (e.g. the Orders .twb), run the converter from a clean
`sigma-data-model-mcp` checkout pinned to origin/main — see
`tableau/orders-overview/MANIFEST.md`.
