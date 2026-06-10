# Quickstart — Cognos → Sigma converter

Runnable in ~1 minute on the bundled real-IBM-sample fixtures. No Cognos access needed.

```bash
cd skills/cognos-to-sigma/converter
npm install            # fast-xml-parser + tsx
npm test               # convert every fixture in ../fixtures
```

Expected:

```
✓ go-sales-performance.report.xml    report → 2 tables · 6 cols · 1 controls
✓ great-outdoors.module.json         module → 25 elems · 114 cols · 10 metrics · 14 rels
✓ sample-data-module.module.json     module → 4 elems · 63 cols · 26 metrics · 0 rels
✓ telco-churn.module.json            module → 8 elems · 244 cols · 21 metrics · 7 rels
all fixtures converted ✓
```

## Convert one artifact

**Data Module JSON → Sigma data model:**
```bash
node --import tsx/esm cli.ts ../fixtures/great-outdoors.module.json --database CSA --schema PUBLIC
```
→ Sigma data-model JSON on stdout; `stats` + per-calc `warnings` on stderr (the warnings
are exactly the bits that need manual authoring — read them).

**Report-spec XML → Sigma workbook:**
```bash
node --import tsx/esm cli.ts ../fixtures/go-sales-performance.report.xml --dm <dataModelId>
```
→ Sigma workbook JSON. Lists become table elements, dataItems become columns,
`prompt(...)` become controls; the prompt-driven "swap measure" macro is flagged with
a `Switch([…])` placeholder.

## Pull your own from Cognos

```bash
export COGNOS_BASE="https://<host>/bi/v1"
export COGNOS_COOKIE="…"   export COGNOS_XSRF="…"      # from DevTools → Copy as cURL
../scripts/cognos-discover.sh list   <folderId>
../scripts/cognos-discover.sh module <moduleId> > my.module.json
../scripts/cognos-discover.sh report <reportId> > my.report.xml
node --import tsx/esm cli.ts my.module.json
```

Then post the outputs to Sigma (`/v2/dataModels/spec`, `/v2/workbooks/spec`) — see `SKILL.md`
Phases 2–4 for the readback-and-wire + verify steps.
