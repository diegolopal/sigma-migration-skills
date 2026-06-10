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
 * NOT yet: crosstabs→pivot, charts (RAVE2), drill-through→actions, conditional
 * render blocks, master-detail. Those are the research long-tail.
 */

import { XMLParser } from 'fast-xml-parser';
import { resetIds, sigmaShortId, sigmaDisplayName } from './sigma-ids.js';
import { translateCognosExpr, type CognosQuerySubject } from './cognos.js';

const xmlParser = new XMLParser({
  ignoreAttributes: false, attributeNamePrefix: '@_', trimValues: true,
  isArray: (n) => ['query', 'dataItem', 'list', 'page', 'detailFilter', 'summaryFilter',
    'dataItemValue', 'dataItemLabel', 'listColumn', 'reportPage'].includes(n),
});
const arr = (v: any): any[] => (Array.isArray(v) ? v : v == null ? [] : [v]);
const txt = (v: any): string => (v == null ? '' : typeof v === 'object' ? (v['#text'] ?? '') : String(v));

// ── workbook spec types (minimal) ────────────────────────────────────────────
interface WbColumn { id: string; name: string; formula: string; }
interface WbControl { id: string; kind: 'control'; controlId: string; name: string; controlType: string; }
interface WbElement { id: string; kind: string; name: string; source: Record<string, any>; columns?: WbColumn[]; order?: string[]; filters?: any[]; }
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
    tables: pageEls.length,
    columns: pageEls.reduce((n, e) => n + (e.columns?.length || 0), 0),
    controls: controls.size,
  };
  return {
    workbook: { name: reportName, schemaVersion: 1, pages, controls: controlEls },
    warnings, stats,
  };
}
