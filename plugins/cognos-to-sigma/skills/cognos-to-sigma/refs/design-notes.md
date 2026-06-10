# Cognos → Sigma — converter design notes

The original design sketch for the `cognos-to-sigma` skill. The converter is now
BUILT and live-validated (`converter/` — Data Module JSON → Sigma DM, report-spec
XML → Sigma workbook incl. crosstabs/charts/maps/KPIs/macros/filters); this doc is
kept for the translation surface, hard problems, and reuse notes. Where it
disagrees with `format-shapes.md` or the code, trust those.

> Status: HISTORICAL design doc (converter shipped). Last touched 2026-06-10.

---

## Source formats

IBM Cognos Analytics has **two semantic-layer formats** plus a **report-spec XML**
plus a **dashboard JSON** — pick the right input per asset.

| Artifact | Format | Notes |
|---|---|---|
| **Report Specification** | XML, IBM-published XSDs in `/schemas/rspec/10.0/*.xsd` (ships with Cognos SDK). 10.0 schema is still current in CA 11.x / 12.x. | The primary, well-defined artifact — every Cognos Report Studio / CA Reporting report is a single XML doc. **This is the main input.** |
| **Framework Manager package** | `.cpf` + project XML. Legacy semantic layer. | CWM/XMI export drops joins, prompts, folders, namespaces, calculations — **don't use CWM**. Parse the raw `.cpf` / project XML directly. |
| **Data Module** | JSON. CA 11.x's modern semantic layer; replaces Framework Manager. | **Cleanest input.** Native JSON export supported as of recent CA 11.x. Where a customer has migrated FM→DM, this is the high-fidelity path. |
| **Dashboard** | JSON in the content store (distinct from "Reports"). | Separate code path from report-spec XML. |
| **Deployment archive** | `.zip` produced by `cogtr.sh` / Lifecycle Manager. Bundles report specs + metadata. | Practical input format when a customer dumps a content store. |

Schema reference: [Cognos SDK v10.2.1 Report Specification Schema Reference v10.0](https://www.ibm.com/support/pages/cognos-software-development-kit-v1021-report-specification-schema-reference-v100).

---

## API access

CA 11.1+ exposes REST at **`/bi/v1/...`** (NOT `/api/v1` — that base path only serves
`PUT /api/v1/session` for login; content sub-resources 403 on it). Same surface
on-prem and Cognos Analytics on Cloud (SaaS).

- Auth: session cookie + `X-XSRF-Token` (CAM credentials / API key via `PUT /api/v1/session`).
- Discovery: `GET /bi/v1/objects/{id}/items?fields=defaultName,type,id`.
- Report spec download: `GET /bi/v1/objects/{id}?fields=specification` — returns the report-spec XML as a string property.
- Data module: `GET /bi/v1/metadata/modules/{id}` — returns the data module JSON (the plain `/modules/{id}` returns EMPTY).

Working REST wrappers (use as reference, don't depend on them):
- Python: [ykud/cognosanalyticspy](https://github.com/ykud/cognosanalyticspy) — real auth + content-tree traversal
- JS: [CognosExt/jcognos](https://github.com/CognosExt/jcognos)

Docs:
- [CA 12.0 REST API overview](https://www.ibm.com/docs/en/cognos-analytics/12.0.x?topic=apis-overview)
- [CA 11.2 REST API](https://www.ibm.com/docs/en/cognos-analytics/11.2.x?topic=apis-rest-api)
- [REST getting started](https://www.ibm.com/docs/en/cognos-analytics/12.0.x?topic=api-getting-started-rest)
- [IBM API Hub Cognos catalog](https://developer.ibm.com/apis/catalog/cognosanalytics--cognos-analytics-rest-api/)

---

## Translation surface

| Cognos concept | Sigma equivalent | Difficulty |
|---|---|---|
| Data Module (JSON) | Data model | easy — closest 1:1 in the BI converter universe |
| Framework Manager package (`.cpf`) | Data model | medium — namespaced model, requires resolving query subjects to physical tables |
| Query Subject | Source table (or `join` element if model-side) | easy |
| Query Item | Column | easy |
| Calculation (data-module or report-level) | Calculated column / formula | medium — Cognos expression DSL ≠ Sigma; mapping needed |
| Detail Filter / Summary Filter | DM filter or workbook filter | easy |
| Report page | Workbook page | easy |
| List | Table element | easy |
| Crosstab | Pivot element | medium — nested-edge axes, must populate `rowsBy` + `columnsBy` arrays |
| Chart (RAVE2 JSON spec embedded in report XML) | Chart element | medium — needs RAVE2 mini-parser |
| Prompt / Prompt Page | Control element | medium — prompt cascades + value-providers |
| Drill-through definition | Action | hard — target-report binding |
| Conditional style | Conditional formatting | partial — Cognos has richer style rules |
| Sub-query (`<query>` nested in report XML) | No 1:1 — must either inline or land in warehouse | **hard** |
| Master-detail relationship | No clean Sigma analog — sometimes a pivot, sometimes a related DM element | **hard** |
| Burst / Schedule / Email | Sigma scheduled exports | medium — config-only translation |
| Active Report | **Drop** — interactive client-side widget tree | out of scope |

### Cognos expression DSL

A SQL-ish hybrid with MDX echoes. Examples:
- `total([Revenue] for [Product line])` → `SumOver([Revenue], [Product line])`
- `if ([Status] = 'OK') then (1) else (0)` → `If([Status] = "OK", 1, 0)`
- `running-total([Revenue] for [Order date])` → window equivalent
- `_add_days([Order date], 30)` → `DateAdd("day", 30, [Order date])`

Many functions have direct Sigma analogs. `for` clauses → Sigma `*Over` window
functions. The `running-total` family + master-detail are the hardest.

---

## Reverse-engineering difficulty

- **Report-spec XML is documented** (IBM ships the XSDs) — easier than Power BI, comparable to or better than Tableau `.twb`.
- **No mature OSS report-spec parser** found. Closest prior art:
  - [JohnLBevan EAM exporter gist](https://gist.github.com/JohnLBevan/e5343987863198a47fea2e9aab067d86) — XML dump + git
  - Senturus [Cognos Migration Assistant](https://senturus.com/products/cognos-migration-assistant/) — commercial, targets Power BI / Fabric / Tableau (not Sigma)
  - PMsquare / Motio tooling — commercial
  - SnowConvert AI — does **not** cover Cognos report logic
- No prior Cognos → Sigma work, OSS or commercial, found.
- Framework Manager vs Data Module split: [Senturus blog](https://senturus.com/blog/cognos-framework-manager-vs-data-modules/) is a useful primer; [Talend MIMB FM bridge](https://help.qlik.com/talend/en-US/talend-data-catalog/8.0/Content/MIRCognosRnFrameworkManager2Export.htm) documents what CWM drops.

---

## MVP scope (4–6 focused weeks, comparable to early Tableau curve)

Phase 0: REST discovery + content-tree download (mirror `tableau-assessment`).

Phase 1: **Data Module JSON → Sigma DM.** Highest leverage, cleanest input. Cover query subjects → tables, query items → columns, calculations → formulas, joins → DM relations.

Phase 2: **Report-spec XML → Sigma workbook spec.** Pages, lists, basic charts, crosstabs (with `rowsBy`/`columnsBy`), prompts as controls, simple filters.

Phase 3: **Framework Manager `.cpf` → Sigma DM.** Fallback for customers still on the legacy semantic layer. Parse raw project XML; ignore CWM export.

Phase 4: Cognos expression DSL → Sigma formula. Lift the `formulas.ts` pattern from the Tableau converter; build a function-map table.

Phase 5: Assessment skill (`cognos-assessment`) — REST inventory + per-report complexity scan, same shape as `tableau-assessment`.

### Long-tail (months 2–3 of iteration)

- Sub-queries
- Master-detail relationships
- RAVE2 custom visualizations
- Conditional render blocks
- Burst / drill-through
- Active Report (drop)

---

## Effort estimate

**Bigger than Tableau core converter, smaller than Power BI.**
- Tableau core converter: ~2–3 weeks
- Cognos core converter MVP: ~4–6 weeks
- Long-tail parity: another 2–3 months of iteration — same curve shape as Tableau

Drivers of the size delta vs Tableau:
1. **Dual semantic-layer formats** — FM `.cpf` + Data Module JSON, both need code paths
2. **Richer expression DSL** — more functions, MDX-style scope (`for`), running-totals
3. **Crosstab nested-edge axes** — more complex than Tableau pivots
4. **Two artifact formats per asset** — report-spec XML *and* dashboard JSON

---

## What's reusable from `tableau-to-sigma`

- `scripts/lib/` token / auth wrapper pattern → `cognos-to-sigma/scripts/lib/cognos_rest.rb`
- `formulas.ts` translation table approach → `cognos_formulas.ts`
- Phase 0a complexity gap-scan pattern (`scan-workbook-gaps.rb`)
- Phase 5 workbook repointing — once the DM is built, re-point the workbook spec columns
- Cluster / DM-reuse orchestration (leader/follower) — applies as-is
- PNG-read step from `feedback_phase1d_dashboard_png` — useful for any chart kind we can't auto-detect from XML

Not reusable:
- The .twb/.tds XML parser itself (different schema)
- The VizQL Data Service usage (Cognos has no equivalent — falls back to running the report)
