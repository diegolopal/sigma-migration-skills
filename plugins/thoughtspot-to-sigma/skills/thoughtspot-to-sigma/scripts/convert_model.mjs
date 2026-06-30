#!/usr/bin/env node
// Convert a ThoughtSpot model TML file to a Sigma data-model spec (JSON to stdout).
// Usage: node convert_model.mjs <model.tml>
//   env: SIGMA_CONNECTION_ID, TS_DB, TS_SCHEMA, CONVERTER_PATH (build/thoughtspot.js)
import { readFileSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
// Converter resolution: explicit CONVERTER_PATH (a dev's fresher build) wins;
// otherwise the self-contained bundle vendored in the skill (no clone, no MCP).
const HERE = dirname(fileURLToPath(import.meta.url));
const VENDORED = join(HERE, '..', 'converter', 'thoughtspot.mjs');
const CONV = process.env.CONVERTER_PATH || (existsSync(VENDORED) ? VENDORED : null);
if (!CONV) { console.error('no converter: set CONVERTER_PATH (sigma-data-model-mcp build/thoughtspot.js) or restore the vendored converter/thoughtspot.mjs'); process.exit(2); }
const { convertThoughtSpotToSigma } = await import(CONV);
const tml = readFileSync(process.argv[2], 'utf8');
const r = convertThoughtSpotToSigma(tml, {
  connectionId: process.env.SIGMA_CONNECTION_ID,
  database: process.env.TS_DB || '',
  schema: process.env.TS_SCHEMA || '',
});
process.stdout.write(JSON.stringify({ model: r.model, stats: r.stats, warnings: r.warnings }));
