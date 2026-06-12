# tableau / structural-workarounds

Hand-authored minimal .twb exercising the three structural Tableau gaps closed
2026-06-11 (beads y6b / iq8 / t67b): a 3-point STORY, a cross-source BLEND, and
a NESTED `{FIXED}` LOD plus the ISOYEAR / FINDNTH / bin calc translations.
Synthetic XML (no live tenant) modeled on real Tableau 2024.1 .twb shapes; the
CSA.TJ Snowflake connection block matches the live demo warehouse.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | Synthetic workbook XML: 3 worksheets, 1 dashboard, 1 storyboard (3 story points), Snowflake primary + textscan secondary blend, nested-FIXED / iso-year / FINDNTH / bin calc columns |
| `get-workbook.json`, `views/*.csv`, `master-columns.json` | Minimal discovery fixtures so `build-charts-from-signals.rb` runs offline |
| `wb-spec.json`, `wb-ids.json` | Workbook-spec + readback-ids fixtures for `build-story-pages.rb` pass 1 / pass 2 |
| `story-plan.json` | PINNED `parse-twb-layout.rb` output: 1 story, 3 points (dashboard + 2 worksheet captures) |
| `blend-plan.json` | PINNED `scan-workbook-gaps.rb` output: 1 blend, linking field `Region`, route `materialize-via-vds` (textscan secondary) |
| `chart-specs-lod-chains.json` | PINNED `build-charts-from-signals.rb` sidecar: 2-level nested-FIXED helper chain (`LOD Helper 1` = Sum(Sales) by Region+Customer Id → `LOD Helper 2` = Avg by Region) |

## Converter

No MCP converter — this case pins the SKILL-script contracts. Regenerate with
the tableau-to-sigma skill scripts (`$S` = `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`):

```
ruby $S/parse-twb-layout.rb workbook-content.twb dashboard-layout.json   # → story-plan.json (+ layout/meta)
ruby $S/scan-workbook-gaps.rb workbook-content.twb gaps-report.md       # → blend-plan.json (+ gaps report)
ruby $S/build-charts-from-signals.rb --tableau-dir . --layout dashboard-layout.json \
  --meta dashboard-layout-meta.json --master-map master-columns.json \
  --out chart-specs.json                                                # → chart-specs-lod-chains.json
ruby $S/build-story-pages.rb --story-plan story-plan.json --spec wb-spec.json \
  --out wb-spec-with-story.json                                         # pass 1 (3 caption-named pages)
ruby $S/build-story-pages.rb --story-plan story-plan.json --wb-ids wb-ids.json \
  --layout-out story-layout.xml                                         # pass 2 (banded layouts + sidecar)
```

Diff the regenerated `story-plan.json` / `blend-plan.json` /
`chart-specs-lod-chains.json` against the pinned copies — they are
deterministic (no generated ids). `dashboard-layout*.json`, `gaps-report.*`,
`chart-specs.json`, `wb-spec-with-story.json` and `story-layout.xml*` are
regenerable intermediates and are not pinned.

## Assertions encoded by the pins

- story-plan: 3 points in story order; `sheet_kind` resolves `Overview Dash`
  → `dashboard`, the two sheets → `worksheet`; storyboard dashboard flagged
  `is_story: true` in dashboard-layout.json.
- blend-plan: blend detected ONLY on the 2-datasource worksheet; linking
  field = `Region` (caption present in both dependency blocks); textscan
  secondary routes to `materialize-via-vds` per refs/blending.md.
- lod-chains: innermost-first decomposition; outer level consumes
  `[LOD Helper 1/Value]`; final = `[LOD Helper 2/Value]`.
- build-charts WARNs carry the ISOYEAR Thursday-shift formula, the FINDNTH
  array composition, and the BinFixed/BinRange recipe (width 100, peg 0).

## Known parity reference (live run 2026-06-11)

Formula patterns verified on org tj-wells-1989 / conn `bc0319f8` / `CSA.TJ`
(workbook "Gap Workarounds 2026-06-11", folder of the same name), each tied to
warehouse SQL via sigma-mcp-v2:

- **ISOYEAR** Thursday-shift on `CUSTOMER_DIM.FIRST_ORDER_DATE`: per-iso-year
  counts 2019–2024 = 2/3/7/5/5/3, exact match vs `DATE_PART('isoyear', …)`.
- **FINDNTH** (2nd `.` in `EMAIL`): sum 378 across 25 rows, exact match vs
  `SPLIT_PART` SQL — **after** correcting `ArraySlice` start to 0 (start=1
  silently skips the first segment; live run caught a +2/row drift).
- **BinFixed**(`LIFETIME_REVENUE`, 0, 100000, 10): bin counts 18/2/1/1/2/1,
  exact match vs `FLOOR(rev/10000)+1` — BinFixed's bin index is 1-based.
- **2-level nested-LOD helper chain** on `ORDER_FACT` (Sum NET_REVENUE by
  channel×customer → Avg by channel): App 687.80791667 / In-Store 1279.7308 /
  Online 2417.98, exact match vs nested `GROUP BY` SQL — **only when the outer
  element's source carries `groupingId`**; a plain element source reads
  base-grain rows (row-weighted Avg, e.g. App 969.82 ≠ 687.81).

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "get-workbook.json", "format": "json"},
    {"path": "master-columns.json", "format": "json"},
    {"path": "wb-spec.json", "format": "json"},
    {"path": "wb-ids.json", "format": "json"},
    {"path": "story-plan.json", "format": "json"},
    {"path": "blend-plan.json", "format": "json"},
    {"path": "chart-specs-lod-chains.json", "format": "json"}
  ]
}
```
