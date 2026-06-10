// Smoke test on the bundled fixtures: node --import tsx/esm test.ts
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { convertCognosToSigma } from './cognos.js';
import { convertCognosReportToSigma } from './cognos-report.js';

const FIX = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');
let fail = 0;
for (const f of readdirSync(FIX)) {
  try {
    if (f.endsWith('.module.json')) {
      const r = convertCognosToSigma(readFileSync(join(FIX, f), 'utf8'), { connectionId: 'c', database: 'DB', schema: 'S' });
      if (!r.model.pages[0].elements.length) throw new Error('no elements');
      console.log(`✓ ${f.padEnd(34)} module → ${r.stats.elements} elems · ${r.stats.columns} cols · ${r.stats.metrics} metrics · ${r.stats.relationships} rels`);
    } else if (f.endsWith('.report.xml')) {
      const r = convertCognosReportToSigma(readFileSync(join(FIX, f), 'utf8'), { dataModelId: 'dm' });
      console.log(`✓ ${f.padEnd(34)} report → ${r.stats.tables} tables · ${r.stats.columns} cols · ${r.stats.controls} controls`);
    }
  } catch (e: any) { fail++; console.log(`✗ ${f} — ${e.message}`); }
}
console.log(fail ? `\n${fail} FAILED` : '\nall fixtures converted ✓');
process.exit(fail ? 1 : 0);
