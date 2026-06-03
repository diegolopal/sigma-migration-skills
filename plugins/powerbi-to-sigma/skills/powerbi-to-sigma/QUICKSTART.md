author: Sigma Computing
summary: Migrating from Power BI made easy — convert Power BI reports to Sigma with Claude Code
id: developers_migrating_from_powerbi_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/sigmacomputing/quickstarts-public/issues

# Migrating from Power BI to Sigma made easy

## Introduction & why it matters
Duration: 2

Manually rebuilding Power BI reports in another tool means re-creating the semantic
model, re-writing every DAX measure, and re-laying-out each page — then proving the
numbers still match.

This quickstart automates it with **Claude Code** + a set of Power BI→Sigma skills: it
extracts the semantic model (TMSL) and report layout (PBIR) from Fabric, translates DAX
measures to Sigma formulas, builds a Sigma data model + workbook, and **verifies data
parity** against the same warehouse.

positive
: DAX → Sigma is the heart of this migration. ~70% of measures are *mechanical* (direct rewrites); time-intelligence (YTD, same-period-last-year, running totals) maps to Sigma's `DateLookback`/`CumulativeSum` in a date-grouped element; only a small genuine tail has no equivalent.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- Power BI developers evaluating a move to Sigma

The skills carry the DAX and Sigma-spec knowledge. You need access to a Power BI /
Fabric tenant and a Sigma org whose connection reaches the same warehouse the semantic
model queries (import or DirectQuery).

## Prerequisites
Duration: 2

- **Claude Code** (CLI or desktop) installed
- **Python** with `msal` + `truststore` (for Microsoft auth over corporate TLS)
- **Power BI / Fabric access** — you do **not** need to register an Entra app. The skill uses **device-code auth** with the well-known Power BI Desktop public client, which works against *My workspace* and any workspace you can access.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`)
- A **Sigma connection to the same warehouse** the model uses (for parity)
- The **`convert_powerbi_to_sigma`** converter (part of the sigma-data-model MCP)

negative
: Two API audiences are involved — **Fabric** (`api.fabric.microsoft.com`) for `getDefinition` (TMSL/PBIR) and **Power BI REST** (`analysis.windows.net/powerbi`) for refresh history, Activity Events, and `executeQueries` (DAX parity). The skill acquires both from one device-code session; corporate TLS requires `truststore.inject_into_ssl()`.

## The two-skill ecosystem
Duration: 2

| Skill | Role |
|---|---|
| **`powerbi-assessment`** | Inventory a Fabric tenant + score per-report complexity: DAX-convertibility buckets (a/b/c), visual-kind coverage, RLS roles, DirectQuery, warehouse sources parsed from M → value/cost-ranked shortlist. Run first. |
| **`powerbi-to-sigma`** | The conversion: extract TMSL+PBIR → translate DAX → build Sigma data model + workbook → parity-verify via `executeQueries`. |

Same `value/(1+cost)` shortlist math and `migrate-first / easy-win / moderate /
needs-gap-scout / retire` tags as the Tableau and Qlik migration skills.

## Installation & setup
Duration: 5

1. **Clone the skills** (sparse checkout):
   ```bash
   git clone --filter=blob:none --sparse https://github.com/sigmacomputing/quickstarts-public
   cd quickstarts-public && git sparse-checkout set powerbi-migration-skills
   ```
2. **Symlink into Claude Code:**
   ```bash
   ln -s "$PWD/powerbi-migration-skills/powerbi-to-sigma"   ~/.claude/skills/powerbi-to-sigma
   ln -s "$PWD/powerbi-migration-skills/powerbi-assessment" ~/.claude/skills/powerbi-assessment
   ```
3. **Sigma credentials** — export `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`; `scripts/get-token.sh` exchanges them for a `SIGMA_API_TOKEN`.
4. **Power BI auth** — run the device-code flow:
   ```bash
   python3 powerbi-to-sigma/scripts/fabric-auth-check.py   # opens device-code login, caches token
   ```
   Sign in with an account that can see the target workspace.
5. **Verify:** `python3 powerbi-to-sigma/scripts/fabric-inventory.py` lists your workspaces + items.

## Prepare demo data (optional)
Duration: 3

If you don't have a report to migrate, build a small model against your warehouse: a
fact + a few dimension tables (Power Query M sources pointing at, say, Snowflake), a
handful of DAX measures (`SUM`, `DIVIDE`, a `CALCULATE` with a single filter,
`TOTALYTD`), and a one-page report with a few visuals. Make sure your Sigma connection
points at the same schema.

## Run the conversion
Duration: 10

Point the `powerbi-to-sigma` skill at a report/dataset. Phases:

1. **Extract** (`fabric-extract.py`) — device-code → Fabric `getDefinition` →
   **TMSL** (tables, measures, calc columns, RLS, M sources) + **PBIR** (pages, visuals,
   field bindings). Classic single-`report.json` reports are handled too
   (`extract-report-classic.py`).
2. **Translate** — `convert_powerbi_to_sigma` maps the model + DAX to a Sigma spec.
   Apply the required POST fixups (`schemaVersion`, folderId, element name).
3. **Build the data model** — POST to `/v2/dataModels/spec`; verify every column has a
   concrete type (no `error` columns).
4. **Build the workbook** — recreate the report pages/visuals as Sigma elements +
   layout.
5. **Verify parity** — `phase6-parity-pbi.rb` runs the original measures via Power BI
   `executeQueries` (DAX) and compares to Sigma `query`.

positive
: For many reports, the assessment's migration plan clusters reports by shared semantic model so you reuse one Sigma data model across a batch.

## Understanding the output
Duration: 3

- **Assessment readout** (`powerbi-assessment`) — per-report DAX buckets (a/b/c), visual
  histogram, RLS/DirectQuery flags, warehouse sources, and a ranked shortlist.
- **DAX buckets:** **a** = mechanical direct rewrite (~70%); **b** = restructure (grouped
  element / parallel join / pre-aggregation — e.g. `RANKX`, `ALLEXCEPT`, `SUMMARIZE`);
  **c** = no Sigma equivalent (rare — `PATH` hierarchies, dynamic context).
- **Parity check** — GREEN only when `executeQueries` DAX results match Sigma.

## Reference & gotchas
Duration: 3

- **Extraction with no Entra app** — device-code + well-known client + `truststore`; works on *My workspace*.
- **PBIR vs classic report.json** — newer reports are exploded PBIR; older ones are a single `report.json` with `sections[]` — detect and branch.
- **Spec fixups** — three required edits before POST (`schemaVersion: 1`, real `folderId`, element `name`).
- **Time-intelligence DAX** is translatable (not part of the (c) tail) via `DateLookback`/`CumulativeSum` on a date-grouped workbook element.
- **Writing layout back to Power BI** (reverse path) uses Fabric `updateDefinition` with an allow-listed parts set.

## The techniques worth carrying forward
Duration: 1

- **Assess first** — DAX buckets tell you effort before you touch a report.
- **Extract model + report together** — TMSL gives the semantics, PBIR gives the layout.
- **Treat the warehouse as the source of truth** — parity via `executeQueries` is the gate.
- **Cluster by semantic model** — migrate a family of reports onto one Sigma data model.

Next: run `powerbi-assessment` on your tenant, pick the shortlist, and let
`powerbi-to-sigma` convert the top N.
