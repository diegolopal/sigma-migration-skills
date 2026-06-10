// Convert a LookML explore to a Sigma data-model spec file, running the
// converter directly against a source tree (bypasses the deployed MCP build —
// see SKILL.md "Converter-build gotcha").
//
// Usage:
//   LOOKML_DIR=/path/to/lookml-project \
//   CONVERTER_SRC=/path/to/sigma-data-model-mcp/src/lookml.ts \
//     node --import tsx/esm convert_dm.mjs <exploreName> <out.json>
//
// LOOKML_DIR must contain <something>.model.lkml + a views/ dir of *.view.lkml.
// CONVERTER_SRC points at the converter's lookml.ts (so you get the latest fixes
// without waiting for the long-running MCP server to reload). SIGMA_CONNECTION_ID
// is written into the spec as a placeholder; post_dm.py swaps in the full UUID.
import fs from 'fs';
import path from 'path';
import { pathToFileURL } from 'url';

const explore = process.argv[2] || 'order_fact';
const out = process.argv[3] || '/tmp/looker_dm.json';

const dir = process.env.LOOKML_DIR;
if (!dir) { console.error('Set LOOKML_DIR=/path/to/lookml-project'); process.exit(1); }
const converterSrc = process.env.CONVERTER_SRC;
if (!converterSrc) { console.error('Set CONVERTER_SRC=/path/to/sigma-data-model-mcp/src/lookml.ts'); process.exit(1); }
const connectionId = process.env.SIGMA_CONNECTION_ID || 'PLACEHOLDER_CONNECTION_ID';

const { convertLookMLToSigma } = await import(pathToFileURL(converterSrc).href);

const modelFile = fs.readdirSync(dir).find(f => f.endsWith('.model.lkml'));
if (!modelFile) { console.error(`No *.model.lkml in ${dir}`); process.exit(1); }
const files = [{ name: modelFile, content: fs.readFileSync(path.join(dir, modelFile), 'utf8') }];
const viewsDir = path.join(dir, 'views');
for (const f of fs.readdirSync(viewsDir)) {
  if (f.endsWith('.view.lkml'))
    files.push({ name: f, content: fs.readFileSync(path.join(viewsDir, f), 'utf8') });
}

const res = convertLookMLToSigma(files, { connectionId, exploreName: explore, joinStrategy: 'relationships' });
fs.writeFileSync(out, JSON.stringify(res.model, null, 2));   // NOTE: return prop is `.model`, not `.sigmaDataModel`
console.error(`explore=${explore} -> ${out}`);
console.error('stats:', JSON.stringify(res.stats));
console.error('warnings:', res.warnings.length);
res.warnings.forEach(w => console.error('  ' + w));
