# QuickSight → Sigma: complexity taxonomy + 20-dashboard test slate

Reference for validating the quicksight-to-sigma skill against graduated complexity.
Grounded in the QuickSight `describe-analysis-definition` schema and cross-referenced
against this stack's known coverage + gaps.

## Converter / builder coverage snapshot
- **DM converter** (MCP `convert_quicksight_to_sigma`): handles RelationalTable, CustomSql,
  JoinInstruction, DataTransforms (CreateColumns/Rename/Cast/Filter/Project), calc fields
  (~40 functions; `ifelse`→If, `switch`→nested If). Params → Sigma controls.
- **DM GAPS**: window/table-calc functions (~28+: sumOver, runningSum, rank, lag/lead via
  periodOverPeriod*, percentOfTotal, window*, percentile*Over) → `/* TODO */` placeholder;
  S3Source & SaaSTable → placeholder; analysis-level FilterGroups → skipped;
  ColumnConfigurations (formatting) → skipped; dataset-of-datasets → out of scope.
- **Workbook builder** recreates: KPI, bar, line, donut/pie. NOT built: table, pivot, combo,
  scatter, gauge, funnel, treemap, histogram, boxplot, waterfall, sankey, wordcloud, radar,
  maps (geospatial/filled/layer), insight, customcontent, plugin.

## Visual catalog (API `Visual` union — 24 nodes)
BUILT: `KPIVisual`, `BarChartVisual`, `LineChartVisual`, `PieChartVisual`.
NOT BUILT: `ComboChartVisual`, `TableVisual`, `PivotTableVisual`, `ScatterPlotVisual`,
`HeatMapVisual`, `GaugeChartVisual`, `FunnelChartVisual`, `TreeMapVisual`, `HistogramVisual`,
`BoxPlotVisual`, `WaterfallVisual`, `SankeyDiagramVisual`, `WordCloudVisual`, `RadarChartVisual`,
`GeospatialMapVisual`, `FilledMapVisual`, `LayerMapVisual`, `InsightVisual`,
`CustomContentVisual`, `PluginVisual`, `EmptyVisual`(no-op).

## Complexity axes (easy / medium / hard)
- **A. Data topology**: 1 RelationalTable → CustomSql → multi-table JoinInstruction → dataset-of-datasets(out of scope). S3/SaaS sources = GAP.
- **B. Data prep**: simple calc fields → transforms chain → window/table-calc funcs (GAP) / LAC.
- **C. Visual types**: KPI/bar/line/pie → mid catalog (table/pivot/combo/…) → maps/sankey → insight/custom/plugin (un-migratable).
- **D. Interactivity**: 1 filter control → param controls + relative-date → cascading/cross-sheet (FilterGroups GAP) → actions/drill (GAP).
- **E. Layout**: single tiled grid → multi-sheet/fixed grid → free-form (pixel) / section-based (paginated). Free-form & section → approximate to Sigma grid.
- **F. Governance/advanced**: text/images/themes → conditional formatting (GAP) → RLS/CLS → insight ML (un-migratable).

## The 20-dashboard slate (low → high)
**Tier 1 — trivial smoke (pass clean):**
- D1 Single KPI (total revenue). baseline happy path.
- D2 Bar by Region, simple `sum` calc.
- D3 Line trend + Pie mix (multi-element grid).

**Tier 2 — medium real-world:**
- D4 Exec summary: 4 KPIs + bar + line + 1 filter control (sheet scope).
- D5 CustomSql dataset → bar + **table** (table builder).
- D6 Two-dataset **JoinInstruction** (orders⋈customers) → bar + KPI (cross-element ref form).
- D7 **Parameters** + param controls (slider/dropdown) + what-if calc.
- D8 **Combo** (dual-axis) + **Scatter** (size+color).
- D9 **Gauge** + **Funnel** + **TreeMap**.
- D10 Data-prep **transforms** chain (Create/Rename/Cast/Filter) → bar+KPI on derived cols.

**Tier 3 — hard (hit gaps):**
- D11 **Pivot table** multi-level (2 row dims, 1 col, 2 measures, subtotals) — rowsBy/columnsBy `{id}` arrays.
- D12 **Window/table-calc** funcs (runningSum, percentOfTotal, rank, periodOverPeriod) → verify graceful `/* TODO */` degradation.
- D13 **Cascading + cross-sheet filters** (FilterGroup AllSheets) — FilterGroups GAP.
- D14 **Visual actions**: filter + navigation(+param) + URL — actions GAP (inventory/warn).
- D15 **Free-form layout** w/ overlap + text box + image.
- D16 **Section-based** paginated report (header/footer/page-break) + table.
- D17 **Maps**: geospatial points + filled choropleth.
- D18 **Exotic zoo**: waterfall + sankey + boxplot + histogram + wordcloud + radar.

**Tier 4 — very hard / governance + un-migratable:**
- D19 **RLS + CLS** secured + conditional formatting (color rules, data bars) on a table.
- D20 **Kitchen sink**: multi-dataset join + window calcs + cascading params + free-form + **InsightVisual (ML) + CustomContent + Plugin** — verify clean PARTIAL migration + full warning manifest.
- (optional D21: dataset-of-datasets recursion — negative test for the out-of-scope case.)

## Un-migratable → scope as known-(c)-tail, never "failed":
`InsightVisual` ML (forecast/anomaly/narrative); `CustomContentVisual` (iframe/HTML); `PluginVisual`
(Highcharts etc.); Sankey + map family (best-effort parity); SectionBasedLayout + free-form pixel
overlap; cascading filter *actions*; SPICE ingestion metadata; dataset-of-datasets recursion.
Always emit a partial migration + warning manifest for these.

_Doc sources: QuickSight API_Visual, AnalysisDefinition, FilterGroup/FilterScopeConfiguration,
LayoutConfiguration/GridLayoutConfiguration, custom-actions, table-calculation-functions, RLS/CLS, ML-insights._
