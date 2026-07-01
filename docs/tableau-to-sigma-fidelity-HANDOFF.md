# Tableau → Sigma Fidelity — Engineering Handoff

**Date:** 2026-07-01 · **Scope:** the composition/style fidelity program for `tableau-to-sigma` (design-heavy dashboards).
**Companion docs:** `docs/tableau-to-sigma-phase1-composition-style.md` (Phase-1 design) · `TABLEAU_TO_SIGMA_SKILL_GAPS.md` (original gap report, in `~/Downloads`).
**Backlog:** beads epic `beads-sigma-ubr5` (children `.1`–`.20`, label `tableau-fidelity`).

---

## 0. TL;DR

The converter gets the **data** right (numbers, chart kinds, parity gate) but historically produced **generic composition** — a flat chart band, default palette, no container tints. This program adds the missing **composition/style layer** so an automated conversion reaches the hand-built replica.

**Reference workbook (the benchmark):** *"Estimated U.S. Job Loss from Mass Deportations"* (Tableau Public, `chimdi.nwosu`). Hand-built Sigma target: `https://app.sigmacomputing.com/dataflow/workbook/5RkbujfxygREnBLCd8d89C`. The full target spec bundle (`workbook-live-spec.yaml` = the authoritative oracle) is in `~/Downloads/sigma-spec.zip`. The source `.twb` is downloadable: `curl -L https://public.tableau.com/workbooks/EstimatedU_S_JobLossfromMassDeportations.twb` (it's a `.twbx`).

**Shipped & merged (2026-07-01):** Phase 0 + the color/control slice of Phase 1 (see §2). **Remaining:** the rest of Phase 1 (KPI composites, styled text), the Phase-2 P0s (card-trellis, threshold halo), chart-mark fidelity, transport edge cases, and the Phase-5 visual-diff loop (see §5).

---

## 1. Architecture — the three stages

A conversion flows through three scripts under `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/`. Style must be handled in the right one:

| Stage | Script | Emits | Style belongs here when… |
|-------|--------|-------|--------------------------|
| **Parser** | `parse-twb-layout.rb` (1189→~1240 ln) | per-dashboard `zones[]` (flat) + `zone_tree` (nested) + `-meta.json` (worksheets/params) | it's a signal to **extract** from the `.twb` |
| **Chart builder** | `build-charts-from-signals.rb` (~3870 ln) | element specs (charts/KPIs/controls) + `data_elements`/`control-scope` sidecars | it lives on an **element** (KPI `value.fontSize`, chart `color.scheme`, `dataLabel`, styled text) |
| **Layout** | `build-dashboard-layout.rb` + `lib/layout.rb` | `<GridContainer>`/`<LayoutElement>` XML + `<out>.elements.json` (container specs w/ `style`) | it's **container/band-level** (tint `backgroundColor`, header bar) |
| **Workbook assembler** | `build-workbook-spec.rb` (~215 ln) | the final POST body (`pages`, `themeName`, `themeOverrides`) | it's **workbook-level** (canvas, `categoricalScheme`) |

**Root cause (from the gap report):** the parser read geometry/semantics but never a fill color, palette, or control mode; the builder never emitted them. Phase 1 closes both ends.

**Orchestration:** `migrate-tableau.rb` (agent-driven per `SKILL.md`) runs parse → build-charts → build-dashboard-layout → build-workbook-spec → POST. The converter itself (`.twb` → data model) is the **vendored** `converter/tableau.mjs` (see §4).

---

## 2. What's shipped (merged to `main`, 2026-07-01)

| PR | Gap | Change | Test |
|----|-----|--------|------|
| #241 | Phase 0 A1 | `tableau-discover.rb` — force UTF-8 on the `.twbx`-extract read (em-dash crash) | `ruby -c` |
| #241 | Phase 0 A4 | `scan-workbook-gaps.rb` — surface container-tint / custom-palette / viz-in-tooltip so design-heavy workbooks stop reporting "0 unhandled" | — |
| #241 | — | Phase-1 **design doc** committed | — |
| #242 | parser | `parse-twb-layout.rb` — extract `fill_color`/`border_color` (from `<zone-style>`) + `control_display` (zone `mode`) onto `zones` + `zone_tree` | `test-zone-style-extraction.rb` |
| #244 | **E1** | `build-charts-from-signals.rb` — `controlType` list vs segmented from `control_display` (both emit sites) | `test-control-display-type.rb` |
| #246 | **B2** | `build-dashboard-layout.rb` — container `style.backgroundColor`+`borderColor`+`borderRadius` from the zone tint; broaden the container-tree trigger to styled containers | `test-container-tint.rb` |
| #248 | **D1 + canvas** | `build-workbook-spec.rb` — `themeName` + `themeOverrides` (`backgroundCanvas` + `categoricalScheme` from the source region palette); `--layout` input | `test-theme-derivation.rb` |

Prior (custom-SQL, separate program): #79 (MCP src) / #71 (browser) / #240 (re-vendor) — all merged.

**C5** (auto `dataLabel`) was found **already implemented** (`build-charts-from-signals.rb` L3373-3380) — no change needed.

---

## 3. Key verified facts — DO NOT re-derive these

These cost real investigation this session. They supersede the design doc's earlier guesses.

### 3a. `.twb` style tokens (verified against the real benchmark)
- **Zone fill/border**: the zone's **direct `<zone-style>` child** → `<format attr='background-color'|'border-color' value='#RRGGBBAA'/>`. NOT `<style-rule element='dash-zone'>` (that scope does not exist for zones).
- **Control display**: the zone **`mode`** attr — `compact` → dropdown (`list`), `type_in` → text, absent → button/radio (`segmented`). NOT `param-mode`.
- **Region tints**: 8-digit-alpha hex, base colors **`#07b4a2`** (South/teal) · **`#e8519a`** (West/pink) · **`#827bb8`** (Northeast/purple) · **`#f28e2b`** (Midwest/orange), each at alpha `4e`/`1b`/`0e`.
- **Marks layers** (F6 / C2 halo): `<style-rule element='map-layer'>` / `map-data-layer`.
- **Custom palettes**: `<color-palette custom='true' type='ordered-sequential'>` (these are gradients, not the categorical region palette).

### 3b. THREE color families (the big implementation insight)
The answer-key spec uses three distinct palettes — don't conflate them:
1. **`categoricalScheme`** (saturated marks). Oracle hexes (`#f5a94e/#9186c6/#35bda8/#ec5fa0`) are **hand-tweaks NOT in the `.twb`** → the correct automated target is the **source** Tableau region colors (`#07b4a2` …). *(Shipped in #248.)*
2. **Container tints** (pastel ramp): card `#E4F6F2` → header `#9CE0D4` for teal, etc. The hand-build flattens the alpha tint to a solid pastel; #246 instead passes the 8-digit-alpha tint through verbatim (Sigma renders it over the canvas — faithful, simpler). A future increment could add the pastel-ramp derivation (base → header → card) to match the oracle exactly.
3. **Threshold halo**: fixed `#F2C037` — `color.by: category` on a computed `Over 100K` boolean, `scheme: [regionColor, '#F2C037']`.

### 3c. The answer-key oracle (`~/Downloads/sigma-spec.zip`)
`workbook-live-spec.yaml` is the server-resolved spec — the **field-for-field target** for the `emit_composition` work. Exact values: `themeName: Light`; canvas `#ffffff` (oracle) vs source `#e6e6e6` (faithful); KPI `value.fontSize` **34** (rail) / **44** (region hero); `controlType` list×3 (Metric/Labels/Median) + segmented×2 (share/Rank); `borderRadius: round`; transparent charts `#00000000`; styled text `<span style="background-color:#EDEDED">…**bold**…</span>`. `layout.xml` shows the full 24-col grid: left rail + 6 controls + 4 region columns, each = `hdrbar-*` (header bar container) + `reg-*` container holding `{kpi, pct, sub, mihdr, most, sphdr, strip}`.
Use it as the **spec-diff gate** for future builder work (assert emitted spec matches it) — stronger than pixel diffing.

### 3d. Vendored-converter propagation (custom-SQL program; still relevant)
A Tableau converter change lands in **three** places or it doesn't reach users:
1. `sigma-data-model-mcp/src/tableau.ts` (source of truth) → rebuild.
2. `sigma-data-model-manager/index.html` (browser mirror).
3. **`sigma-migration-skills` re-vendor**: `converter/tableau.mjs` is an esbuild bundle (`PROVENANCE.json` tracks the source commit). Refresh with `scripts/dev/vendor-converter.sh ~/sigma-data-model-mcp`. This is the local, no-egress converter `migrate-tableau.rb` auto-discovers — what customers actually run. **NB:** the composition/style work above is all in the *skill scripts* (parser/builder/layout), NOT the converter, so it does not need re-vendoring.

---

## 4. Customer situation (EDNA / `japham`)

**Symptom:** PODVIEW Custom SQL workbook → "empty data model / converter limitation."
**Diagnosis:** **stale clone.** The current `main` vendored `converter/tableau.mjs` handles top-level Custom SQL (verified: 1 element / 4 cols) and has `maxEntityCount: 5000000` baked in. The customer hand-patching the entity limit (`1e3→1e5`) proves their bundle predates the fix.
**Remediation:** `git pull sigma-migration-skills`; drop the entity-limit patch.
**Still open (recommended follow-up):** two Windows patches are **not upstreamed**, so Windows users re-apply them every pull —
- `get-token.sh`: `base64 | tr -d '\n'` (line-wrap)
- `mechanical-specs.rb`: `file:///` URL prefix for Node ESM on Windows.
Upstreaming these (a small cross-platform PR) removes the recurring drift.

---

## 5. Remaining work — all phases

Priorities/owners from `TABLEAU_TO_SIGMA_SKILL_GAPS.md`. Effort: **S** ≈ hours, **M** ≈ 1 day, **L** ≈ multi-day. All gated by `synth-twb-e2e.rb` + the fleet PNG gate + (ideally) a spec-diff vs the oracle.

### Phase 1 — finish the composition/style layer
| Gap | What | Files | Effort |
|-----|------|-------|--------|
| **B3** | KPI composites (label + big value + side annotation). Emit container + label `text` + `kpi-chart{name:' ', value.fontSize:34/44, style.backgroundColor:'#00000000'}` + annotation `text`. Needs a parser `kpi_composite` signal (a `kpi` zone that is a child of a captioned container with an annotation sibling). | parser `parse-twb-layout.rb` (derive near L990); builder `build-charts-from-signals.rb` (`build_kpi_element`, ~L1625) | **M** |
| **B4** | Rich styled static text (subtitle, annotations, pill/badge, credit). Parser: `text_runs` (`<formatted-text><run fontcolor/fontsize/bold>`), `text_align`, `is_pill`. Builder: `text` `body` with `<span style="color/background-color/font-size">` + `**bold**`. | parser (text zones); builder (title/text emit ~L3044) | **M** |
| **B5** | Section headers (`### `) from Tableau sub-captions ("The Most Impacted States"). | builder | **S** |
| **Pass-7** | Transparent chart `style.backgroundColor:'#00000000'` when a chart sits inside a tinted container (so the tint shows through instead of a white card). Needs the layout stage to know the chart's container is tinted. | build-dashboard-layout / build-charts | **M** |

### Phase 2 — highest-leverage P0s (build on Phase 1 primitives)
| Gap | What | Files | Effort |
|-----|------|-------|--------|
| **B1** | **Card-trellis** — the 4 repeated per-region container cards. Detect a container repeated per dimension member → emit N `GridContainer`s, each with a per-category element filter (`[Region]="West"`) + the shared color map. **Biggest visual win; hardest.** Reference `layout.xml` in the oracle for the exact 4-column structure. | parser (detect repetition) + builder + layout | **L** |
| **C2** | **Threshold / second-layer highlight** (the yellow >100K halo). Emit a computed boolean column `[m] > N` + chart `color:{by:category, scheme:[regionColor, '#F2C037']}` + WARN the halo is approximated. Needs marks-layer detection (`element='map-layer'`, §3a). | builder | **M** |
| **D2** | Consistent per-category color everywhere: pin one `category→color` dict + a fixed category sort so a region keeps its color across all charts. (`categoricalScheme` from #248 gives the colors; this pins the ordering.) | builder | **S** |

### Phase 3 — chart-mark fidelity + interactivity
| Gap | What | Effort |
|-----|------|--------|
| **C1** | Strip/jitter plots → scatter with a synthesized spread axis + WARN jitter not reproducible | **M** |
| **C3** | Lollipop (dot+bar) → bar with `dataLabel` + WARN dot layer dropped | **S** |
| **C4** | Normalized single-row proportion bar renders empty → substitute grouped/text bar or drop w/ WARN | **S** |
| **E2** | Parameter-driven measure switch → `Switch()`/branch formula bound to the (now correctly-typed, #244) control | **M** |
| **E3** | Set/filter actions → auto-wire single-select control + `If([State]=[ctl])` (SET) / same-page cross-element filters (value) | **M** |

### Phase 4 — transport (parallelizable, independent of style)
| Gap | What | Files | Effort |
|-----|------|-------|--------|
| **A2** | Embedded unpublished `excel-direct` source has no land path → detect `datasourceIsPublished=false`+`excel-direct`; land via view-CSV→warehouse table (or prompt for `.xlsx`); short-circuit the VDS route w/ a clear message | discover/builder | **M** |
| **A3** | `hasExtracts=true` but `downloadWorkbook` returns no `.hyper` → reconstruct the fact from `get-view-data` CSVs | `tableau-discover.rb` | **M** |

### Phase 5 — the one-shot closer
**Visual-diff-and-refine loop inside Phase 6.** Phase 6f already renders a PNG and checks *data* parity. Extend it to diff the render against the source dashboard image (**the Tableau source**, not another Sigma render) and iterate on design deltas — automating the 7 manual passes. Build on the existing `layout-visual-qa` rubric + fleet PNG gate. **Now that #246/#248 emit style, add a cheaper spec-level gate first:** diff the emitted workbook spec against the oracle `workbook-live-spec.yaml` before the pixel diff. **Effort: L.**

### F1–F6 — WARN-only (no Sigma spec path; never "fix")
Per-series color on stacked charts (F1), in-bar labels on normalized bars (F2), viz-in-tooltip (F3), trellis/small-multiples (F4), value-gradient choropleth (F5), multiple marks layers (F6). Surface each in the coverage report; A4 (#241) already surfaces F3. Track under `beads-sigma-ubr5.20`.

---

## 6. Backlog map (beads `beads-sigma-ubr5`)

`cd ~/.beads-sigma && bd list -l tableau-fidelity`

| Bead | Gap | Status |
|------|-----|--------|
| .1 | A1 | ✓ closed (#241) |
| .4 | A4 | ✓ closed (#241) |
| .6 | B2 | ✓ closed (#246) |
| .14 | C5 | ✓ closed (already impl) |
| .15 | D1 | ✓ closed (#248) |
| .17 | E1 | closed/implemented (#242+#244) |
| .5 | B1 | open · **P0** |
| .11 | C2 | open · **P0** |
| .2 | A2 | open · **P0** |
| .7 | B3 | open · P1 |
| .8 | B4 | open · P1 |
| .3 | A3 | open · P1 |
| .10 | C1 | open · P1 |
| .18 | E2 | open · P1 |
| .19 | E3 | open · P1 |
| .9 | B5 | open · P2 |
| .12 | C3 | open · P2 |
| .13 | C4 | open · P2 |
| .16 | D2 | open · P2 |
| .20 | F1–F6 | open · P2 (WARN-only) |

---

## 7. Test / gate infrastructure

**Fast unit tests** (no API; extraction-pattern or synthetic `.twb` → run the real script → assert):
```
ruby scripts/test-zone-style-extraction.rb    # parser fill/border/control_display
ruby scripts/test-control-display-type.rb     # E1 controlType mapping
ruby scripts/test-container-tint.rb           # B2 container tint emit
ruby scripts/test-theme-derivation.rb         # D1 palette + canvas
ruby scripts/test-container-layout.rb         # nested-container regression
ruby scripts/test-layout-lint.rb              # layout lint
```
When adding a builder helper, make it a **top-level `def`** so tests can extract it via `SRC.match(/^def <fn>\b.*?\n^end$/m)` (see the E1/D1 tests) — in-body lambdas aren't extractable.

**End-to-end** (`synth-twb-e2e.rb`): parse → build-charts → build-dashboard-layout → build-workbook-spec → POST. Now passes `--layout` to build-workbook-spec (theme). Needs a Sigma token + a CSA.TJ-landed fact.

**Warehouse/API:** test path is **CSA.TJ** (conn `cb2f5180-…`, folder `9ca9bf60-6a33-43dd-967d-1ba6352c54bb`). Token: `bash -c 'eval "$(scripts/get-token.sh)"; …'` (never `TOKEN=$(eval …)`). Data-model queries for verification go through the `sigma-mcp-v2` MCP (`describe`/`query`) — not a pure-REST endpoint.

**Fleet PNG gate:** the existing Phase-6 visual gate (`verify-dashboard-visual.rb`) must stay green on every composition change.

---

## 8. Resources

- **Benchmark `.twb`:** `curl -L https://public.tableau.com/workbooks/EstimatedU_S_JobLossfromMassDeportations.twb` (a `.twbx`; unzip via `python3 -c "import zipfile; …"`).
- **Answer-key oracle:** `~/Downloads/sigma-spec.zip` → `workbook-live-spec.yaml` (authoritative), `layout.xml`, `datamodel-spec.json`, `README.md`. **Recommend committing this into `docs/benchmarks/job-losses/` as the durable spec-diff oracle.**
- **Design doc:** `docs/tableau-to-sigma-phase1-composition-style.md`.
- **Gap report:** `~/Downloads/TABLEAU_TO_SIGMA_SKILL_GAPS.md`.
- **Live Sigma target:** `https://app.sigmacomputing.com/dataflow/workbook/5RkbujfxygREnBLCd8d89C`.

### Recommended sequence for the next engineer
1. **B3 + B4** (finish Phase-1 composition — KPI composites + styled text). Reuses the parser/builder patterns already established; oracle has exact `fontSize`/text shapes.
2. **C2** (threshold halo — P0, self-contained builder change).
3. **B1** (card-trellis — P0, biggest visual win; the primitives from #246/#248 are its building blocks).
4. **Phase 5 spec-diff gate** against the oracle, then the pixel loop.
5. Parallel: **A2/A3** (transport) and the **Windows-compat** upstream (§4).

**Guiding principle (from the gap report):** every design attribute is already in the `.twb` and expressible in the Sigma spec — the job is to *extract* it (parser) and *emit* it (builder), never to invent. When unsure of a value, prefer the **source** Tableau value over the hand-build's aesthetic tweak (faithfulness), and **WARN, never silently drop**.
