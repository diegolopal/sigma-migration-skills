# Sigma migration skills

A [Claude Code](https://claude.com/claude-code) **plugin marketplace** for migrating
BI tools to [Sigma](https://www.sigmacomputing.com/). Each plugin is a pair of skills —
a **converter** (rebuild the content in Sigma) and an **assessment** (inventory + complexity
+ a value/cost shortlist) — validated end-to-end with **parity checked against the source
warehouse**, not just a best-effort port.

## Install

```text
/plugin marketplace add twells89/sigma-migration-skills
/plugin install tableau-to-sigma@sigma-migration-skills
/plugin install powerbi-to-sigma@sigma-migration-skills
/plugin install qlik-to-sigma@sigma-migration-skills
```

Then just describe what you want migrated — e.g. *"migrate this Power BI report to Sigma"* —
and the skill drives discovery → translation → build → parity.

## What's in the marketplace

| Plugin | Source tool | Skills it installs |
|---|---|---|
| [`tableau-to-sigma`](plugins/tableau-to-sigma/) | Tableau | `tableau-to-sigma`, `tableau-assessment` |
| [`powerbi-to-sigma`](plugins/powerbi-to-sigma/) | Power BI | `powerbi-to-sigma`, `powerbi-assessment` |
| [`qlik-to-sigma`](plugins/qlik-to-sigma/) | Qlik Sense / Cloud | `qlik-to-sigma`, `qlik-assessment` |

Once installed, skills are namespaced — e.g. `/powerbi-to-sigma:powerbi-assessment`.

## The shared shape

Every converter follows the same phased flow:

```
Discover   →  pull the source model + report/sheets/dashboards
Translate  →  measures/calcs/expressions → Sigma formulas (a converter handles the bulk;
              a gap-scout sub-agent validates the hard cases against the live Sigma API)
Data model →  build the Sigma data model (tables + relationships + metrics), reconciled to the warehouse
Workbook   →  rebuild the pages/visuals as a Sigma workbook (layout applied last)
Parity     →  query Sigma vs the source warehouse — GREEN only on a match
```

Each plugin's `skills/<name>/SKILL.md` is the entry point; `refs/` holds the spec
gotchas and `scripts/` the pipeline. Skills are self-contained — no external paths to wire up.

## Requirements

- **Claude Code** with the [Sigma data model converter MCP](https://github.com/twells89/sigma-data-model-mcp) available (provides the `convert_*_to_sigma` tools).
- A **Sigma API token** and a Sigma **connection** pointing at the same warehouse as the source content (needed for the parity gate).
- Per-tool source access — see each plugin's `refs/connection.md` (e.g. `qlik-cli` for Qlik; device-code / Fabric `getDefinition` for Power BI).

## Provenance

The reference migrations and example IDs throughout these skills come from the author's
own Sigma + Snowflake test tenant (a retail/workforce star schema). They're included as
**worked examples** — substitute your own connection, data model, and folder IDs.

## License

[MIT](LICENSE).

---

> **Roadmap:** a `domo-to-sigma` plugin is in development and will join the marketplace
> once it clears the same parity bar.
