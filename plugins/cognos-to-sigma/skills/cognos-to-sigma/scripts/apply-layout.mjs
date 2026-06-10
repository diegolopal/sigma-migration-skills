#!/usr/bin/env node
// apply-layout.mjs — give a migrated Cognos workbook a CLEAN dashboard grid.
//
// Sigma auto-arrange stacks every element at the SAME height (KPIs as tall as tables,
// charts squished) — so for any multi-element page we write an explicit 24-col layout:
// controls in a top row, then content stacked full-width with per-kind heights. Layout
// elementIds must match the POSTED (reassigned) ids, so this GETs the readback spec first.
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/apply-layout.mjs --workbook <workbookId>
//
// Idempotent. Run it as the last step of the build/verify phase.
import { api, parseArgs } from './lib/sigma-rest.mjs';

const a = parseArgs(process.argv.slice(2));
if (!a.workbook) { console.error('need --workbook <workbookId>'); process.exit(2); }

// per-kind row-unit heights (24-col grid; rows are "auto" so spans set relative size)
const H = (k) => k === 'control' ? 2
  : k === 'kpi-chart' ? 6
  : k.endsWith('-chart') ? 10
  : (k.endsWith('-map') || k === 'pivot-table' || k === 'table') ? 12
  : k === 'text' ? 3 : 10;

function pageLayout(page) {
  const els = (page.elements || []).filter((e) => e.id);
  if (els.length < 2) return null; // single element → auto-arrange is fine
  const controls = els.filter((e) => e.kind === 'control');
  const content = els.filter((e) => e.kind !== 'control');
  const lines = [];
  let row = 1;
  // controls: up to 4 across the top
  controls.forEach((c, i) => {
    const perRow = Math.min(controls.length, 4);
    const span = Math.floor(24 / perRow);
    const col0 = 1 + (i % perRow) * span;
    const r = row + Math.floor(i / perRow) * H('control');
    const col1 = (i % perRow === perRow - 1) ? 25 : col0 + span;
    lines.push(`  <LayoutElement elementId="${c.id}" gridColumn="${col0} / ${col1}" gridRow="${r} / ${r + H('control')}"/>`);
  });
  if (controls.length) row += Math.ceil(controls.length / 4) * H('control');
  // content: stacked full-width, per-kind heights (clean, no overlap, right proportions).
  // Exception: RUNS of consecutive kpi-charts lay out as rows of up to 3 TALL tiles
  // (a KPI panel) — full-width singles waste a page and Sigma hides the KPI title
  // below ~5 grid rows, so never shrink them either.
  for (let i = 0; i < content.length; i++) {
    const e = content[i];
    if (e.kind === 'kpi-chart') {
      let j = i; while (j < content.length && content[j].kind === 'kpi-chart') j++;
      const run = content.slice(i, j);
      const perRow = Math.min(run.length, 3);
      const span = Math.floor(24 / perRow);
      run.forEach((k, n) => {
        const col0 = 1 + (n % perRow) * span;
        const col1 = (n % perRow === perRow - 1) ? 25 : col0 + span;
        const r = row + Math.floor(n / perRow) * H('kpi-chart');
        lines.push(`  <LayoutElement elementId="${k.id}" gridColumn="${col0} / ${col1}" gridRow="${r} / ${r + H('kpi-chart')}"/>`);
      });
      row += Math.ceil(run.length / perRow) * H('kpi-chart');
      i = j - 1;
      continue;
    }
    const h = H(e.kind);
    lines.push(`  <LayoutElement elementId="${e.id}" gridColumn="1 / 25" gridRow="${row} / ${row + h}"/>`);
    row += h;
  }
  return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${page.id}">\n${lines.join('\n')}\n</Page>`;
}

const got = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
if (!got.json) { console.error(`GET spec failed (HTTP ${got.status}): ${got.text.slice(0, 300)}`); process.exit(1); }
const spec = got.json;
// The layout is a SINGLE top-level `spec.layout` XML holding one <Page> block per page
// (NOT pages[].layout — that's silently dropped). Strip read-only fields before the PUT.
const pageBlocks = [];
for (const p of spec.pages || []) { delete p.layout; const xml = pageLayout(p); if (xml) pageBlocks.push(xml); }
if (!pageBlocks.length) { console.log('no multi-element pages — nothing to lay out'); process.exit(0); }
spec.layout = `<?xml version="1.0" encoding="utf-8"?>\n${pageBlocks.join('\n')}`;
for (const k of ['workbookId', 'url', 'ownerId', 'createdBy', 'updatedBy', 'createdAt', 'updatedAt', 'latestDocumentVersion', 'documentVersion']) delete spec[k];
if (a.folder && !spec.folderId) spec.folderId = a.folder;

const put = await api('PUT', `/v2/workbooks/${a.workbook}/spec`, spec);
if (!put.ok) { console.error(`PUT failed (HTTP ${put.status}): ${put.text.slice(0, 400)}`); process.exit(1); }

// verify the layout survived readback
const rb = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
const ok = /<LayoutElement/.test(rb.json?.layout || '');
console.log(JSON.stringify({ workbookId: a.workbook, pagesLaidOut: pageBlocks.length, layoutOnReadback: ok }, null, 2));
if (!ok) { console.error('FAIL: layout did not survive readback (check elementId matches)'); process.exit(1); }
console.error(`clean layout applied (${pageBlocks.length} page block(s))`);
