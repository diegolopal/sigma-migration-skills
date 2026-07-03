---
name: looker-to-sigma-reuse
description: >-
  Migrate Looker Looks and Dashboards to Sigma workbooks by REUSING existing
  Sigma Data Models. Unlike the standard looker-to-sigma skill (which creates
  new DMs from LookML), this skill maps Looker fields to columns in existing
  Sigma DMs, respects element visibility, uses relationships for cross-element
  access, and never writes raw SQL. Requires Looker API credentials and
  Sigma API credentials stored as Cortex secrets.
---

# Looker-to-Sigma Migration (DM Reuse)

Migrate Looker content to Sigma workbooks by reusing existing Sigma Data Models.

## Core Rules

These rules are non-negotiable. Follow them in every migration.

### 1. Prefer existing Sigma Data Models

Always search for an existing DM first. If one covers the explore (even
partially), use it. Only create a new DM if no existing model covers the needed
tables/domain -- and always notify the user first before proceeding.

**How:** Search Sigma DMs by explore name, source table names, and domain
keywords. Use `scripts/find_matching_dm.py` or the Sigma MCP search tools.

### 2. Never use SQL queries

All data must come from data model elements and their columns/relationships.
Do not create Custom SQL elements or write raw SQL in workbooks.

**Why:** SQL bypasses the semantic layer, breaks governance, and makes
workbooks unmaintainable.

### 3. Only use VISIBLE elements

Check `visibleAsSource: false` in the DM spec. Never source a workbook from a
hidden element, even though the API allows it.

**How:** Run `scripts/check_visibility.py <dm_id>` or GET the DM spec and look
for `visibleAsSource: false`. Elements WITHOUT this field are visible (default
is true).

**If the needed columns are in a hidden element:** Access them through a
relationship from a visible element using cross-element formula notation:
`[VisibleElement/RelationshipTargetName/Column Display Name]`

### 4. Use existing relationships

Access columns from related tables via the DM's pre-defined relationships. Do
not attempt to create new joins or relationships.

**How:** Get the DM spec, find the `relationships` array on the visible element,
identify the target element name, then use the formula notation above.

### 5. Verify if the Looker explore already exists as a Sigma DM

Before starting any migration, check if the explore (or its equivalent tables)
is already modeled in Sigma. Most explores have already been replicated.

### 6. Document gaps, don't hack around them

If a Looker field has no equivalent in any Sigma DM (no column, no relationship
path), document it as a gap. Do not write SQL, create new DM elements, or modify
existing DMs to fill it.

---

## Prerequisites

### Looker API credentials (Cortex secrets)

```bash
cortex secret store looker_client_id
cortex secret store looker_client_secret
cortex secret store looker_base_url    # include :19999 port
```

### Sigma API credentials (Cortex secrets)

```bash
cortex secret store sigma_client_id
cortex secret store sigma_client_secret
```

### Test connectivity

```bash
# Looker
cortex secret run --map looker_client_id=LOOKER_CLIENT_ID \
  --map looker_client_secret=LOOKER_CLIENT_SECRET \
  --map looker_base_url=LOOKER_BASE_URL -- bash -c '
mkdir -p ~/.looker && cat > ~/.looker/looker.ini << EOF
[Looker]
base_url=${LOOKER_BASE_URL}
client_id=${LOOKER_CLIENT_ID}
client_secret=${LOOKER_CLIENT_SECRET}
verify_ssl=True
EOF
python3 scripts/looker_api.py whoami'

# Sigma (via MCP -- just search for any workbook)
```

---

## Migration Workflow

### Phase 1: Fetch Looker Content

Get the Look or Dashboard details from Looker API:
- Look: `GET /looks/{id}`
- Dashboard: `GET /dashboards/{id}`

Extract:
- `query.fields` -- dimensions and measures used
- `query.filters` -- active filters with default values
- `query.view` -- the source explore name
- `query.model` -- the LookML model
- `query.vis_config.type` -- visualization type
- `query.sorts` -- sort order

### Phase 2: Find Matching Sigma DM

Search Sigma for a data model that covers the Looker explore's tables.

```bash
python3 scripts/find_matching_dm.py --explore fact_account_usage \
  --tables "dim_sl_accounts_scd,dim_sl_teams_scd,fact_account_usage"
```

The script searches by:
1. Explore name as a keyword
2. Source table names (mapped to ANALYTICS_DB equivalents)
3. Domain keywords from the table names

### Phase 3: Check Element Visibility

```bash
python3 scripts/check_visibility.py --dm-id <data_model_id>
```

Output shows which elements are visible and their relationships. Only use
visible elements as the workbook source.

### Phase 4: Map Fields

For each Looker field, find the corresponding Sigma column:

| Looker Pattern | Sigma Formula |
|---|---|
| Direct column on visible element | `[ElementName/Column Display Name]` |
| Column on a related (hidden) element | `[VisibleElement/RelTargetName/Column Display Name]` |
| Looker calculated field (sql:) | Check if DM has equivalent calc col; else document as gap |
| Looker derived table field | Check if DM has a relationship to equivalent data; else gap |

**Column name matching:** Looker uses `view.column_name` format (snake_case).
Sigma DMs use display names (Title Case). Map `last_session_time` to
`Last Session Date`, `crm_type` to `Crm Type`, etc.

**Boolean fields:** Looker displays booleans as "Yes"/"No" strings. Sigma uses
native `true`/`false`. Do not attempt to create text-based filters on boolean
columns via the API.

### Phase 5: Build Workbook Spec

```bash
python3 scripts/build_workbook_spec.py \
  --dm-id <data_model_id> \
  --element-id <visible_element_id> \
  --element-name "Element Display Name" \
  --mapping mapping.json \
  --page-name "Report Name" \
  --output /tmp/workbook-spec.yaml
```

The script generates a valid YAML spec that:
- Uses only the visible element as source
- References cross-element columns via relationship notation
- Only includes `controlType: number` controls (others need UI)
- Never includes boolean filters (always invalid via API)
- Documents what needs manual UI work in comments

### Phase 6: Create and Apply

```bash
# Create empty workbook
curl -X POST /v2/workbooks -d '{"name": "...", "folderId": "..."}'

# Apply spec
curl -X PUT /v2/workbooks/{id}/spec -H "Content-Type: application/yaml" \
  --data-binary @/tmp/workbook-spec.yaml
```

### Phase 7: Document Gaps and Manual Steps

Every migration produces a summary:

```
## Migration Summary: Look #836

### Migrated fields:
- Full Name -> [Salesloft Users Current State/User Name]
- Email -> [Salesloft Users Current State/User Email]
- Last Session Date -> [Salesloft Users Current State/Last Session Date]

### Gaps (not available in any Sigma DM):
- last_session_source: Derived table in Looker (dbt_prod.vw_identifies),
  not migrated to ANALYTICS_DB
- last_activity_source: Same as above

### Manual UI steps needed:
- Add filter: Active = True
- Add filter: Deleted = False
- Add Team Name control (text/list type)
```

---

## API Limitations (critical)

Read `reference/api-limitations.md` for full details. Summary:

| Feature | API Support | Workaround |
|---|---|---|
| `controlType: number` | YES | -- |
| `controlType: text-input` | NO | Add in UI |
| `controlType: list` | NO | Add in UI |
| `controlType: date-range` | NO | Add in UI |
| Boolean filters (values: true/false) | NO (shows "Invalid filter") | Add in UI |
| VARIANT/JSON column extraction | NO | Use UI "Extract Columns" |
| Cross-element formulas | YES | `[Elem/Rel/Col]` notation |
| Element-level filters (non-boolean) | YES | e.g. text equality filters |

---

## Table Name Mapping (DATAWAREHOUSE -> ANALYTICS_DB)

Looker references DATAWAREHOUSE tables. Sigma DMs use ANALYTICS_DB. Common mappings:

| DATAWAREHOUSE (Looker) | ANALYTICS_DB (Sigma) |
|---|---|
| `dbt_prod.dim_sl_accounts_scd` | `DAILY_SNAPSHOTS.SNAPSHOT_DIM_SALESLOFT__USERS` |
| `dbt_prod.dim_sl_teams_scd` | `DAILY_SNAPSHOTS.SNAPSHOT_DIM_SALESLOFT__TEAMS` |
| `dbt_prod.fact_account_usage` | `REPORTS.RPT_SALESLOFT__TEAM_USAGE` (approx) |
| `dbt_prod.dim_sl_crm_sync_settings_scd` | `STAGING.STG_MELODY__CRM_SYNC_SETTINGS` |
| `dbt_prod.dim_sfdc_accounts_scd` | `DAILY_SNAPSHOTS.SNAPSHOT_DIM__ACCOUNTS` |

This is a living table -- add mappings as you discover them.

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/find_matching_dm.py` | Search Sigma for DMs matching a Looker explore's tables |
| `scripts/check_visibility.py` | List visible/hidden elements and relationships in a DM |
| `scripts/build_workbook_spec.py` | Generate YAML workbook spec from a field mapping |
| `scripts/verify_parity.py` | Compare Looker vs Sigma query results for a sample |
