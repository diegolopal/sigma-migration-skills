#!/usr/bin/env node
/**
 * Cognos → Sigma converter CLI.
 *   node --import tsx/esm cli.ts <data-module.json | report.xml> [opts]
 *
 * Auto-detects input:  *.json → Data Module → Sigma data model
 *                      *.xml  → report spec  → Sigma workbook
 *
 * Options: --connection <id> --database <DB> --schema <S> --dm <dataModelId> --pretty
 */
import { readFileSync } from 'node:fs';
import { convertCognosToSigma } from './cognos.js';
import { convertCognosReportToSigma } from './cognos-report.js';

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const opt = (k: string, d = '') => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
if (!file) { console.error('usage: cli.ts <module.json|report.xml> [--connection X --database DB --schema S --dm ID]'); process.exit(1); }

const xml = readFileSync(file, 'utf8');
const isReport = file.endsWith('.xml') || xml.trimStart().startsWith('<');
const res = isReport
  ? convertCognosReportToSigma(xml, { dataModelId: opt('dm', '<DM_ID>') })
  : convertCognosToSigma(xml, { connectionId: opt('connection', '<CONNECTION_ID>'), database: opt('database'), schema: opt('schema') });

const payload = isReport ? (res as any).workbook : (res as any).model;
process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
console.error(`\n[${isReport ? 'report→workbook' : 'module→data-model'}] stats: ${JSON.stringify(res.stats)}`);
if (res.warnings.length) {
  console.error(`warnings (${res.warnings.length}) — translated where possible, flagged where not:`);
  res.warnings.forEach((w) => console.error('  ! ' + w));
}
