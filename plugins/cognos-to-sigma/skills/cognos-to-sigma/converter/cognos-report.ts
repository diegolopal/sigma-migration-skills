/**
 * IBM Cognos report-spec XML → Sigma workbook spec.   [LOCAL / WIP — not registered]
 *
 * Phase 2 of the Cognos converter (Phase 1 = Data Module JSON → DM, in cognos.ts).
 * MVP scope = **list reports** (the most common Cognos report kind):
 *   <query> + <dataItem><expression>  → the dataset (maps to the migrated DM element)
 *   <list refQuery=…> + its columns    → a Sigma `table` element with those columns
 *   model ref [C].[Module].[Subject].[Col] → [Subject/Col] (resolves against the DM)
 *   dataItem cross-ref [Other Item]        → [Other Item] (sibling column)
 *   prompt('p', …)                         → a Sigma control [+ control registered]
 *   detail/summary filter                  → element filter (expression translated)
 *   aggregate / if / date DSL              → reuses translateCognosExpr (cognos.ts)
 *
 * FLAG-don't-fake: Cognos report MACROS (`# … prompt('x','token',…) … #` that build
 * SQL/column refs at runtime — e.g. a "swap measure" picker) have no clean static
 * Sigma analog; they're emitted as a Switch placeholder + a loud warning.
 *
 * Crosstabs → pivot-tables and charts (RAVE2 `<vizControl>`) → Sigma chart
 * elements are supported. NOT yet: drill-through→actions, conditional render
 * blocks, master-detail. Those are the research long-tail.
 */

import { XMLParser } from 'fast-xml-parser';
import { resetIds, sigmaShortId, sigmaDisplayName } from './sigma-ids.js';
import { translateCognosExpr, type CognosQuerySubject } from './cognos.js';

const xmlParser = new XMLParser({
  ignoreAttributes: false, attributeNamePrefix: '@_', trimValues: true,
  isArray: (n) => ['query', 'dataItem', 'list', 'page', 'detailFilter', 'summaryFilter',
    'dataItemValue', 'dataItemLabel', 'listColumn', 'reportPage',
    'crosstab', 'crosstabNode', 'crosstabNodeMember',
    'vizControl', 'vcDataSet', 'vcSlotData', 'vcSlotDsColumn', 'reportDataStore'].includes(n),
});
const arr = (v: any): any[] => (Array.isArray(v) ? v : v == null ? [] : [v]);
const txt = (v: any): string => (v == null ? '' : typeof v === 'object' ? (v['#text'] ?? '') : String(v));

// ── workbook spec types (minimal) ────────────────────────────────────────────
interface WbColumn { id: string; name: string; formula: string; }
interface WbControl { id: string; kind: 'control'; controlId: string; name: string; controlType: string; }
interface WbElement {
  id: string; kind: string; name: string; source: Record<string, any>;
  columns?: WbColumn[]; order?: string[]; filters?: any[];
  rowsBy?: Array<{ id: string }>; columnsBy?: Array<{ id: string }>; values?: string[];   // pivot
  xAxis?: { columnId: string; sort?: any }; yAxis?: { columnIds: string[] };               // cartesian charts
  value?: { id: string }; color?: any; stacking?: string; orientation?: string;            // pie/donut + bar styling
}
interface WbPage { id: string; name: string; elements: WbElement[]; }
export interface CognosReportResult {
  workbook: { name: string; schemaVersion: number; pages: WbPage[]; controls?: WbControl[] };
  warnings: string[];
  stats: Record<string, number>;
}
export interface CognosReportOptions { dataModelId?: string; workbookName?: string; }

// ── ingest ────────────────────────────────────────────────────────────────────
interface DataItem { name: string; expression: string; }
interface Query { name: string; subject: string; items: Map<string, DataItem>; }

function findAll(node: any, tag: string, out: any[] = []): any[] {
  if (node && typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) {
      if (k === tag) arr(v).forEach((x) => out.push(x));
      arr(v).forEach((x) => (x && typeof x === 'object') && findAll(x, tag, out));
    }
  }
  return out;
}

// ── convert ─────────────────────────────────────────────────────────────────
export function convertCognosReportToSigma(xml: string, options: CognosReportOptions = {}): CognosReportResult {
  resetIds();
  const warnings: string[] = [];
  const parsed = xmlParser.parse(xml);
  const report = parsed.report || parsed;
  const reportName = txt(report.reportName) || options.workbookName || 'Cognos Report';

  // 1) queries → dataItem maps. Track the dominant model subject per query.
  const queries = new Map<string, Query>();
  for (const q of findAll(report.queries || report, 'query')) {
    const name = q['@_name'] || 'query';
    const items = new Map<string, DataItem>();
    let subject = '';
    for (const di of findAll(q, 'dataItem')) {
      const dn = di['@_name']; if (!dn) continue;
      const expr = txt(di.expression);
      items.set(dn, { name: dn, expression: expr });
      const m = expr.match(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[[^\]]+\]/); // [C].[Module].[Subject].[Col]
      if (m && !subject) subject = m[1];
    }
    queries.set(name, { name, subject, items });
  }

  const controls = new Map<string, WbControl>();
  const registerPrompt = (p: string) => {
    if (!controls.has(p)) controls.set(p, { id: sigmaShortId(), kind: 'control', controlId: p, name: sigmaDisplayName(p), controlType: 'list' });
  };

  // expression translation: model refs + dataItem cross-refs + prompts + macros, then the DSL.
  const translate = (expr: string, q: Query): { formula: string; warns: string[] } => {
    const warns: string[] = [];
    let f = (expr || '').trim();

    // Cognos report MACRO ( # … # ) — dynamic SQL/column building (e.g. prompt-driven
    // measure swap). No static Sigma analog.
    if (f.startsWith('#') || /#\s*sql\s*\(|'token'/.test(f)) {
      const promptName = (f.match(/prompt\(\s*'([^']+)'/) || [])[1];
      if (promptName) registerPrompt(promptName);
      warns.push(`dataItem uses a Cognos macro (#…#${promptName ? `, prompt '${promptName}'` : ''}) that builds the column/SQL at runtime — model it in Sigma as a control + Switch([Control], …). Emitted a placeholder.`);
      return { formula: promptName ? `Switch([${sigmaDisplayName(promptName)}] /* map prompt tokens to columns */)` : `/* MACRO — manual: ${f.slice(0, 60)} */`, warns };
    }

    // model column ref → [Subject/Col]   (resolves against the migrated DM element)
    f = f.replace(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g,
      (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
    // shorter model ref [Subject].[Col]
    f = f.replace(/\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
    // dataItem cross-refs [Other Item] → [Other Item] (sibling column; keep display name)
    f = f.replace(/\[([^\]\/]+)\]/g, (whole, nm) => (q.items.has(nm) ? `[${sigmaDisplayName(nm)}]` : whole));
    // prompt('p') standalone → control ref
    f = f.replace(/prompt\(\s*'([^']+)'[^)]*\)/g, (_m, p) => { registerPrompt(p); return `[${sigmaDisplayName(p)}]`; });

    // hand off arithmetic / aggregate / if / date DSL to the shared translator
    const dsl = translateCognosExpr(f, { identifier: q.subject || 'Q', items: [] } as unknown as CognosQuerySubject,
      () => '', {} as any);
    dsl.warnings.forEach((w) => warns.push(w));
    return { formula: dsl.formula, warns };
  };

  // 2) layout lists → table elements
  const pages: WbPage[] = [];
  const reportPages = findAll(report.layouts || report, 'reportPage').concat(findAll(report.layouts || report, 'page'));
  const lists = findAll(report, 'list');
  const pageEls: WbElement[] = [];

  for (const L of lists) {
    const qName = L['@_refQuery'];
    const q = queries.get(qName);
    if (!q) { warnings.push(`<list> refQuery="${qName}" has no matching query — skipped.`); continue; }
    const colRefs: string[] = findAll(L, 'dataItemValue').map((d) => d['@_refDataItem']).filter(Boolean);
    const refs = colRefs.length ? colRefs : [...q.items.keys()];
    const columns: WbColumn[] = [];
    const AGG: Record<string, string> = { total: 'Sum', summary: 'Sum', aggregate: 'Sum', average: 'Avg', count: 'Count', maximum: 'Max', minimum: 'Min' };
    for (const r of refs) {
      const di = q.items.get(r);
      if (!di) {
        // layout aggregate/footer column, e.g. "Total(Revenue)" / "Summary(Revenue)" / "Average(Revenue)1"
        const m = r.match(/^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\((.+?)\)\d*$/i);
        if (m && q.items.get(m[2])) {
          columns.push({ id: sigmaShortId(), name: sigmaDisplayName(r), formula: `${AGG[m[1].toLowerCase()]}([${sigmaDisplayName(m[2])}])` });
          continue;
        }
        warnings.push(`list column "${r}" not found in query "${qName}" — skipped.`); continue;
      }
      const { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${qName}.${r}": ${w}`));
      columns.push({ id: sigmaShortId(), name: sigmaDisplayName(di.name), formula });
    }
    pageEls.push({
      id: sigmaShortId(), kind: 'table', name: `${q.subject ? sigmaDisplayName(q.subject) + ' — ' : ''}${qName}`,
      source: { kind: 'data-model', dataModelId: options.dataModelId || '<DM_ID — wire after posting the data model>', elementId: q.subject ? sigmaDisplayName(q.subject) : '<element>' },
      columns, order: columns.map((c) => c.id),
    });
  }

  // 2b) crosstabs → pivot-table elements (rows edge → rowsBy, columns edge → columnsBy, measure → values)
  const isTotal = (r: string) => /^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\(/i.test(r || '');
  for (const X of findAll(report, 'crosstab')) {
    const qName = X['@_refQuery'];
    const q = queries.get(qName);
    if (!q) { warnings.push(`<crosstab> refQuery="${qName}" has no matching query — skipped.`); continue; }
    const edge = (subtree: any) => [...new Set(findAll(subtree || {}, 'crosstabNodeMember').map((m) => m['@_refDataItem']).filter((r) => r && !isTotal(r)))];
    const rowRefs = edge(X.crosstabRows);
    const colRefs = edge(X.crosstabColumns);
    let measRefs = [...new Set(findAll(X.crosstabCorner || {}, 'dataItemLabel').map((d) => d['@_refDataItem']).filter((r) => r && !isTotal(r)))];
    if (!measRefs.length) measRefs = [...q.items.keys()].filter((k) => !rowRefs.includes(k) && !colRefs.includes(k) && !isTotal(k));
    const cols: WbColumn[] = [];
    const mk = (ref: string, agg: boolean): { id: string } | null => {
      const di = q.items.get(ref); if (!di) { warnings.push(`crosstab "${qName}" member "${ref}" not in query — skipped.`); return null; }
      const { formula, warns } = translate(di.expression, q); warns.forEach((w) => warnings.push(`"${qName}.${ref}": ${w}`));
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(di.name), formula: agg ? `Sum(${formula})` : formula });
      return { id };
    };
    const rowsBy = rowRefs.map((r) => mk(r, false)).filter(Boolean) as Array<{ id: string }>;
    const columnsBy = colRefs.map((c) => mk(c, false)).filter(Boolean) as Array<{ id: string }>;
    // Sigma pivot: rowsBy/columnsBy are {id} objects, values are bare column-id strings.
    const values = (measRefs.map((m) => mk(m, true)).filter(Boolean) as Array<{ id: string }>).map((o) => o.id);
    if (!values.length || (!rowsBy.length && !columnsBy.length)) warnings.push(`crosstab "${qName}" missing a measure or both edges — review the pivot.`);
    pageEls.push({
      id: sigmaShortId(), kind: 'pivot-table', name: `${q.subject ? sigmaDisplayName(q.subject) + ' — ' : ''}${qName} (crosstab)`,
      source: { kind: 'data-model', dataModelId: options.dataModelId || '<DM_ID — wire after posting the data model>', elementId: q.subject ? sigmaDisplayName(q.subject) : '<element>' },
      columns: cols, order: cols.map((c) => c.id), rowsBy, columnsBy, values,
    });
  }

  // 2c) charts (RAVE2 <vizControl>) → Sigma chart elements
  // dataStore name → refQuery: vcDataSet.refDataStore → <reportDataStore name><dsV5ListQuery refQuery>
  const dsToQuery = new Map<string, string>();
  for (const ds of findAll(report, 'reportDataStore')) {
    const nm = ds['@_name'];
    const rq = findAll(ds, 'dsV5ListQuery').map((x: any) => x['@_refQuery']).find(Boolean);
    if (nm && rq) dsToQuery.set(nm, rq);
  }
  const ROLLUP_AGG: Record<string, string> = { total: 'Sum', sum: 'Sum', average: 'Avg', avg: 'Avg', count: 'Count', countdistinct: 'CountDistinct', maximum: 'Max', minimum: 'Min' };
  // Cognos vizControl type → Sigma chart kind (only types with a clean native analog)
  const VIZ_KIND: Record<string, string> = {
    'com.ibm.vis.clusteredbar': 'bar-chart', 'com.ibm.vis.stackedbar': 'bar-chart',
    'com.ibm.vis.clusteredcolumn': 'bar-chart', 'com.ibm.vis.stackedcolumn': 'bar-chart',
    'com.ibm.vis.line': 'line-chart', 'com.ibm.vis.spline': 'line-chart',
    'com.ibm.vis.area': 'area-chart', 'com.ibm.vis.stackedarea': 'area-chart',
    'com.ibm.vis.pie': 'pie-chart', 'com.ibm.vis.donut': 'donut-chart',
    'com.ibm.vis.clusteredcombination': 'combo-chart', 'com.ibm.vis.stackedcombination': 'combo-chart',
    'com.ibm.vis.bubble': 'scatter-chart', 'com.ibm.vis.scatter': 'scatter-chart',
  };
  // types Sigma has no native chart for — emit the data as a table + a loud flag (don't fake the viz)
  const VIZ_NOANALOG: Record<string, string> = {
    'com.ibm.vis.tiledmap': 'map', 'com.ibm.vis.network': 'network diagram',
    'com.ibm.vis.wordcloud': 'word cloud', 'com.ibm.vis.packedbubble': 'packed bubble',
    'com.ibm.vis.treemap': 'treemap',
  };
  const chartSource = (q: Query) => ({ kind: 'data-model', dataModelId: options.dataModelId || '<DM_ID — wire after posting the data model>', elementId: q.subject ? sigmaDisplayName(q.subject) : '<element>' });

  for (const V of findAll(report, 'vizControl')) {
    const vizType = String(V['@_type'] || '').toLowerCase();
    const vizName = V['@_name'] || 'Chart';
    const dsName = findAll(V, 'vcDataSet').map((d: any) => d['@_refDataStore']).find(Boolean);
    const qName = dsName ? dsToQuery.get(dsName) : undefined;
    const q = qName ? queries.get(qName) : undefined;
    if (!q) { warnings.push(`<vizControl> "${vizName}" (${vizType}): no resolvable query (dataStore "${dsName}") — chart skipped.`); continue; }

    // slot entries by id (categories / series / values / size / x / y / color)
    const slot = (id: string): Array<{ ref: string; rollup?: string }> => {
      const out: Array<{ ref: string; rollup?: string }> = [];
      for (const sd of findAll(V, 'vcSlotData')) {
        if (String(sd['@_idSlot'] || '').toLowerCase() !== id) continue;
        for (const c of findAll(sd, 'vcSlotDsColumn')) if (c['@_refDsColumn']) out.push({ ref: c['@_refDsColumn'], rollup: c['@_rollupMethod'] });
      }
      return out;
    };
    const cols: WbColumn[] = [];
    const seen = new Map<string, string>();
    const addCol = (e: { ref: string; rollup?: string } | undefined, measure: boolean): string | undefined => {
      if (!e) return undefined;
      const di = q.items.get(e.ref);
      if (!di) { warnings.push(`chart "${vizName}" column "${e.ref}" not in query "${qName}" — skipped.`); return undefined; }
      const nm = sigmaDisplayName(di.name);
      if (seen.has(nm)) return seen.get(nm);
      const { formula, warns } = translate(di.expression, q); warns.forEach((w) => warnings.push(`"${vizName}.${e.ref}": ${w}`));
      const id = sigmaShortId();
      const fn = measure ? (ROLLUP_AGG[String(e.rollup || '').toLowerCase()] || 'Sum') : '';
      cols.push({ id, name: nm, formula: measure ? `${fn}(${formula})` : formula });
      seen.set(nm, id); return id;
    };

    const cats = slot('categories'), series = slot('series'), vals = slot('values');
    const sizes = slot('size'), xs = slot('x'), ys = slot('y'), colorSlot = slot('color');
    const kind = VIZ_KIND[vizType];

    if (!kind) {
      // no native Sigma chart → table fallback + flag (collect every slot column, incl. map latlong/etc.)
      const label = VIZ_NOANALOG[vizType] || vizType.replace('com.ibm.vis.', '');
      for (const c of findAll(V, 'vcSlotDsColumn')) if (c['@_refDsColumn']) addCol({ ref: c['@_refDsColumn'], rollup: c['@_rollupMethod'] }, !!c['@_rollupMethod']);
      if (!cols.length) { warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable columns — skipped.`); continue; }
      warnings.push(`chart "${vizName}" is a Cognos ${label} (${vizType}) — Sigma has no native equivalent; emitted its data as a table. Re-pick a Sigma chart in the workbook.`);
      pageEls.push({ id: sigmaShortId(), kind: 'table', name: `${vizName} (was ${label})`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) });
      continue;
    }

    const el: WbElement = { id: sigmaShortId(), kind, name: vizName, source: chartSource(q), columns: [], order: [] };

    if (kind === 'pie-chart' || kind === 'donut-chart') {
      const colorId = addCol(cats[0] || colorSlot[0], false);
      const valId = addCol(vals[0] || sizes[0], true);
      if (colorId) el.color = { id: colorId };
      if (valId) el.value = { id: valId };
    } else if (kind === 'scatter-chart') {
      const xId = addCol(xs[0] || cats[0], false);
      const yId = addCol(ys[0] || vals[0] || sizes[0], true);
      if (xId) el.xAxis = { columnId: xId };
      if (yId) el.yAxis = { columnIds: [yId] };
      const cId = addCol(series[0] || colorSlot[0], false);
      if (cId) el.color = { by: 'category', column: cId };
    } else {
      // cartesian: bar / line / area / combo
      const xId = addCol(cats[0], false);
      if (xId) el.xAxis = { columnId: xId };
      if (cats.length > 1) { warnings.push(`chart "${vizName}": Cognos used ${cats.length} category levels; Sigma x-axis takes one — bound the first, kept the rest as columns.`); cats.slice(1).forEach((c) => addCol(c, false)); }
      const yIds = [...vals, ...sizes].map((v) => addCol(v, true)).filter(Boolean) as string[];
      if (yIds.length) el.yAxis = { columnIds: yIds };
      else warnings.push(`chart "${vizName}" (${kind}) resolved no measure for the value axis — add a measure in the workbook.`);
      const cId = addCol(series[0] || colorSlot[0], false);
      if (cId) el.color = { by: 'category', column: cId };
      if (kind === 'bar-chart') {
        el.stacking = /stacked/.test(vizType) ? 'stacked' : 'none';
        if (/\bbar\b/.test(vizType) && !/column/.test(vizType)) el.orientation = 'horizontal'; // Cognos "bar" = horizontal
      }
      if (kind === 'combo-chart' && yIds.length > 1) warnings.push(`chart "${vizName}" → combo-chart: all measures placed on the primary axis as the same mark — set per-series shape / secondary axis in the workbook.`);
    }

    el.columns = cols; el.order = cols.map((c) => c.id);
    if (!cols.length) { warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable slot columns — skipped.`); continue; }
    pageEls.push(el);
  }

  // attach controls as page-level elements too
  const controlEls = [...controls.values()];
  pages.push({ id: sigmaShortId(), name: reportPages[0]?.['@_name'] || 'Report', elements: [...controlEls as any, ...pageEls] });

  // filters → warnings (translate for reference)
  for (const fnode of findAll(report, 'detailFilter').concat(findAll(report, 'summaryFilter'))) {
    const fexpr = txt(fnode.filterExpression || fnode.expression);
    if (fexpr) warnings.push(`filter: "${fexpr.slice(0, 80)}" — re-create as a Sigma element/page filter.`);
  }

  const stats = {
    queries: queries.size,
    tables: pageEls.filter((e) => e.kind === 'table').length,
    pivots: pageEls.filter((e) => e.kind === 'pivot-table').length,
    charts: pageEls.filter((e) => e.kind.endsWith('-chart')).length,
    columns: pageEls.reduce((n, e) => n + (e.columns?.length || 0), 0),
    controls: controls.size,
  };
  return {
    workbook: { name: reportName, schemaVersion: 1, pages, controls: controlEls },
    warnings, stats,
  };
}
