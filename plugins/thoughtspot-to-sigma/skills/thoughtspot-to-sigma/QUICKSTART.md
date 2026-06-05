author: Sigma Computing
summary: Migrating from ThoughtSpot made easy — convert ThoughtSpot models and Liveboards to Sigma with your coding agent
id: developers_migrating_from_thoughtspot_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/sigmacomputing/quickstarts-public/issues

# Migrating from ThoughtSpot to Sigma made easy

## Introduction & why it matters
Duration: 2

Rebuilding ThoughtSpot Liveboards in a new BI tool by hand is slow and error-prone —
you re-derive the data model from the worksheet/model TML, re-create every viz and its
search-query filters, and hope the numbers still tie out.

This quickstart automates the whole path with **your coding agent** (Claude Code,
Cursor, Cortex Code, …) + a set of ThoughtSpot→Sigma skills: it discovers a ThoughtSpot
model and its Liveboards, converts the model's TML to a Sigma data model, rebuilds each
Liveboard's visualizations as Sigma elements, applies a grid layout, and **verifies data
parity** against the same warehouse — typically to the cent.

positive
: These skills are **agent-neutral** — each is a `SKILL.md` plus `scripts/`. `AGENTS.md` at the repo root maps each task to its skill, and the scripts auto-load credentials from `~/.sigma-migration/env`, so they run the same under any agent. Where this guide says "Claude Code," substitute your agent.

positive
: The Sigma side reads your warehouse **live**, so the migrated workbook stays current with no extract/refresh step — a difference you'll see in the parity check when new rows land.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- ThoughtSpot developers evaluating a move to Sigma

You do **not** need to be a Sigma or ThoughtSpot internals expert — the skills carry the
domain knowledge. You do need access to a ThoughtSpot instance and a Sigma org whose
connection reaches the same warehouse the ThoughtSpot model's tables live in.

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, Cortex Code, etc.
- **Python 3** on your PATH (the discovery + migrate scripts are Python; model conversion uses a small Node script, `convert_model.mjs`).
- **ThoughtSpot access** — REST API v2 reachable, with a bearer token (see *Authenticate*). Admin is not required, but you need read access to the models/Liveboards you're migrating.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`), plus a target `SIGMA_CONNECTION_ID` (the warehouse connection) and `SIGMA_FOLDER_ID` (where workbooks land).
- A **Sigma connection to the same warehouse** the ThoughtSpot model reads from (for true parity).
- The **`convert_thoughtspot_to_sigma`** converter (part of the sigma-data-model MCP), or a local `sigma-data-model-mcp` build pointed at by `CONVERTER_PATH` for the scripted path.

negative
: ThoughtSpot's chart-type surface is broad. The skill rebuilds the common kinds (KPI, bar, line, pie/donut, pivot, table) plus search-query filters; exotic viz (e.g. geo maps, Spotter/NL tiles) may need a manual pass — the assessment's chart-type coverage flags these before you start.

## The two-skill ecosystem
Duration: 2

| Skill | Role |
|---|---|
| **`thoughtspot-assessment`** | Inventory an instance (models/worksheets, Liveboards, Answers, connections) + score per-Liveboard complexity and chart-type coverage → a value/cost-ranked shortlist. Read-only. Run this first to decide what to migrate. |
| **`thoughtspot-to-sigma`** | The conversion: discover → convert the model TML → build the Sigma data model + workbook → rebuild each Liveboard's viz → layout → parity-verify. |

Both mirror the Tableau, Power BI, and Qlik migration skills: same `value/(1+cost)`
shortlist math and the same `migrate-first / easy-win / moderate / needs-gap-scout /
retire` tags.

## Installation & setup
Duration: 5

1. **Clone the skills** (sparse checkout of the migration folder):
   ```bash
   git clone --filter=blob:none --sparse https://github.com/sigmacomputing/quickstarts-public
   cd quickstarts-public && git sparse-checkout set thoughtspot-migration-skills
   ```
2. **Make the skills available to your agent:**
   - **Claude Code** — symlink them in:
     ```bash
     ln -s "$PWD/thoughtspot-migration-skills/thoughtspot-to-sigma"   ~/.claude/skills/thoughtspot-to-sigma
     ln -s "$PWD/thoughtspot-migration-skills/thoughtspot-assessment" ~/.claude/skills/thoughtspot-assessment
     ```
   - **Other agents (Cursor, Cortex Code, …)** — no install step; open the repo and point your agent at the skill folder. `AGENTS.md` at the repo root indexes every skill.
3. **Sigma credentials** — export `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` (or run `ruby scripts/setup.rb` in the tableau-to-sigma skill, which writes a neutral `~/.sigma-migration/env` the scripts auto-source under any agent). Then mint a token:
   ```bash
   bash -c 'eval "$(scripts/get-token.sh)"; echo "${SIGMA_API_TOKEN:0:8}…"'   # sets SIGMA_BASE_URL + SIGMA_API_TOKEN
   ```
   Also export the workbook targets: `SIGMA_CONNECTION_ID`, `SIGMA_FOLDER_ID`, and the warehouse `TS_DB` / `TS_SCHEMA` the model's tables live in.
4. **ThoughtSpot auth** — set `TS_HOST` and a bearer `TS_TOKEN` (do this in your own terminal so the secret stays out of any transcript):
   ```bash
   # SSO trial with no local password: open this URL in the tab where you're logged in
   #   https://<your>.thoughtspot.cloud/api/rest/2.0/auth/session/token   → copy the `token`
   # OR enable Trusted Auth (Develop → Customizations → Security Settings) and:
   #   POST {TS_HOST}/api/rest/2.0/auth/token/full  with username + secret_key
   export TS_HOST="https://<your>.thoughtspot.cloud"  TS_TOKEN="<bearer>"
   ```
5. **Verify:** `python3 scripts/ts_discover.py` lists your models + Liveboards.

## Prepare demo data (optional)
Duration: 3

If you don't have a Liveboard to migrate, build one against your warehouse (e.g. a
Snowflake retail star: `ORDER_FACT` + `CUSTOMER_DIM` / `PRODUCT_DIM` / `STORE_DIM` /
`DATE_DIM`). In ThoughtSpot, create a **connection** to that schema, a **model/worksheet**
over the star with a couple of formulas, and a **Liveboard** with a handful of tiles
(a KPI, a bar, a line, a pivot). Make sure your Sigma connection points at the same schema.

## Run the conversion
Duration: 10

Point the `thoughtspot-to-sigma` skill at a model. The skill runs these phases
(`scripts/*`):

1. **Discover** (`ts_discover.py`) — list models + Liveboards, summarize a model
   (`<MODEL_ID> LOGICAL_TABLE`), and inspect a Liveboard's viz chart-types + lineage
   (`<LIVEBOARD_ID> LIVEBOARD`).
2. **Convert the model** — feed the model's TML to **`convert_thoughtspot_to_sigma`** (or
   the `convert_model.mjs` scripted path). It emits a Sigma data model with a denormalized
   **"&lt;root&gt; View"** element that surfaces joined-dim columns — the workbook master
   reads from it.
3. **Migrate** (`migrate.py`) — converts + POSTs the DM, discovers the denorm element,
   derives the column resolver from the model TML, rebuilds each Liveboard's
   visualizations as Sigma elements (KPI / bar / line / pie / pivot / table +
   search-query filters), and applies a grid layout (`apply_layouts.py`).
   ```bash
   python3 scripts/migrate.py --model <TS_MODEL_ID>             # all Liveboards on the model
   python3 scripts/migrate.py --model <ID> --liveboard <LB_ID>  # just one
   ```
   Output ids → `~/thoughtspot-migration/migrate_out.json`.
4. **Verify parity** — query the model in ThoughtSpot (`ts_lib.searchdata`) and the Sigma
   workbook elements (Sigma v2 `query`); values match to the cent.

positive
: Re-apply the layout **last** if you edit a workbook spec — a bare PUT wipes `spec.layout`.

## Understanding the output
Duration: 3

- **Assessment readout** (`thoughtspot-assessment`) — per-Liveboard chart-type mix and
  complexity, chart-type coverage, and a value/cost-ranked shortlist driven by
  `TS: BI Server` usage. `scan.py` builds it; `render_html.py` writes a shareable HTML readout.
- **Parity check** — the migration is GREEN only when Sigma's numbers match the warehouse.
- **Migrate output** (`migrate_out.json`) — the created data model + workbook ids per Liveboard.

## Reference & gotchas
Duration: 3

- **Convert the model TML, not raw warehouse tables** — the model's joins + formula
  columns are what produce the denormalized **"&lt;root&gt; View"** the workbook reads from.
- **Search-query filters** on a Liveboard tile map to Sigma element filters; the column
  resolver derived from the model TML maps ThoughtSpot column names → Sigma columns.
- **Auth tokens are short-lived** — ThoughtSpot session tokens expire; re-mint `TS_TOKEN`
  on a 401. Sigma tokens (~1h) are re-fetched by `get-token.sh` / the Ruby libs.
- **Layout is a separate final step** — `apply_layouts.py` runs after the workbook spec;
  re-run it last after any spec edit.

## The techniques worth carrying forward
Duration: 1

- **Assess first** — convert the high-value, low-effort Liveboards before the long tail.
- **Resolve columns from the model TML** — the model's names *are* the column map.
- **Treat the warehouse as the source of truth** — Sigma reads it live; parity is the gate.
- **Rebuild tile-by-tile** — each Liveboard viz becomes one Sigma element.

Next: run `thoughtspot-assessment` on your instance, pick the shortlist, and let
`thoughtspot-to-sigma` convert the top N.
