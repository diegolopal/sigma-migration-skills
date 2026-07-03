# Field Mapping: Looker -> Sigma

## Column Name Conventions

| Looker | Sigma |
|---|---|
| `view.column_name` (snake_case) | `[Element Name/Column Display Name]` (Title Case) |
| `dim_sl_accounts_scd.full_name` | `[Salesloft Users Current State/User Name]` |
| `dim_sl_accounts_scd.email` | `[Salesloft Users Current State/User Email]` |

## Formula Notation

### Direct column (on the visible source element)
```
[Element Name/Column Display Name]
```
Example: `[Salesloft Teams Activity/Team Id]`

### Cross-element column (via relationship to hidden element)
```
[VisibleElement/RelationshipTargetName/Column Display Name]
```
Example: `[Salesloft Teams Activity/SalesLoft Platform CRM Sync Settings/Crm Type]`

The RelationshipTargetName is the `name` field of the TARGET element in the DM spec.

### Calculated column (in workbook)
Standard Sigma formula syntax applies:
```
If([Active] = True, "Yes", "No")
Concat([First Name], " ", [Last Name])
DateDiff("day", [Created At], Now())
```

## Data Type Mapping

| Looker type | Sigma type | Notes |
|---|---|---|
| `string` | `text` | Direct |
| `number` | `integer` or `number` | Sigma distinguishes int vs float |
| `yesno` (boolean) | `boolean` | Looker shows "Yes"/"No", Sigma shows true/false |
| `date` / `date_time` | `datetime` | |
| `tier` | N/A | Calculate with Case/If in workbook |

## Filter Mapping

| Looker filter | Sigma equivalent | Via API? |
|---|---|---|
| `dim.field = "value"` (text) | Element filter, kind: list, values: ["value"] | Depends on type |
| `dim.field = "Yes"` (yesno) | Boolean filter (Active = True) | NO - add in UI |
| `dim.field > 100` (number) | Control with controlType: number | YES |
| `dim_date.is_latest_snapshot = "Yes"` | Filter to max date or latest snapshot_date | Check DM design |

## Common Looker-to-Sigma Column Mappings

This table grows with each migration. Add new mappings as discovered.

| Looker view.field | Sigma Element/Column | DM |
|---|---|---|
| `dim_sl_accounts_scd.full_name` | `Salesloft Users Current State/User Name` | Salesloft Users |
| `dim_sl_accounts_scd.email` | `Salesloft Users Current State/User Email` | Salesloft Users |
| `dim_sl_accounts_scd.last_session_time` | `Salesloft Users Current State/Last Session Date` | Salesloft Users |
| `dim_sl_accounts_scd.last_activity_time` | `Salesloft Users Current State/Last Activity Date` | Salesloft Users |
| `dim_sl_accounts_scd.active` | `Salesloft Users Current State/Active` | Salesloft Users |
| `dim_sl_accounts_scd.deleted` | `Salesloft Users Current State/Deleted` | Salesloft Users |
| `dim_sl_teams_scd.name` | `Salesloft Users Current State/Team Name` | Salesloft Users |
| `dim_sl_crm_sync_settings_scd.crm_type` | via rel: `Salesloft Teams Activity/SalesLoft Platform CRM Sync Settings/Crm Type` | SalesLoft Teams Activity |
| `dim_sl_crm_sync_settings_scd.enabled` | via rel: `Salesloft Teams Activity/SalesLoft Platform CRM Sync Settings/Enabled` | SalesLoft Teams Activity |
| `dim_sl_crm_sync_settings_scd.pollers` | via rel: `Salesloft Teams Activity/SalesLoft Platform CRM Sync Settings/Pollers` (VARIANT - extract in UI) | SalesLoft Teams Activity |

## Known Gaps (Looker fields with no Sigma equivalent)

| Looker field | Reason | Status |
|---|---|---|
| `dim_sl_accounts_scd.last_session_source` | Derived from LookML derived_table (dbt_prod.vw_identifies + vw_sidecar_identifies). Not in ANALYTICS_DB. | Gap - needs data engineering |
| `dim_sl_accounts_scd.last_activity_source` | Same as above | Gap - needs data engineering |
