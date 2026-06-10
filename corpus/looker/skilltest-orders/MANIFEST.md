# looker / skilltest-orders

The validated offline LookML fixture for the looker-to-sigma skill (referenced
from the plugin's `fixtures/skilltest-orders/`, not duplicated): an `order_fact`
explore joining `customer_dim` on CSA.TJ, plus a 6-tile newspaper-layout
`dashboard.lookml`. This is the fixture the skill was built against (GCP trial
could not provision a live Looker, so this is the canonical offline input).

## Artifacts (in plugin fixtures/skilltest-orders/)

| File | What it is |
|---|---|
| `skilltest_orders.model.lkml` | model: connection, include, explore with left_outer many_to_one join |
| `views/order_fact.view.lkml` | 8 dimensions (incl. hidden pk/keys), 3 measures (sum, count_distinct, computed number) |
| `views/customer_dim.view.lkml` | 4 dimensions |
| `skilltest_orders.dashboard.lookml` | 6-tile LookML dashboard (workbook-side input, not consumed by the DM converter) |

## Features exercised

- Multi-file LookML (model + views) with include: warning path
- `${TABLE}.COL` and `${view.field}` substitution; measure-on-measure SQL
  (`1.0 * ${total_net_revenue} / NULLIF(${order_count}, 0)`)
- `value_format_name: usd` → Sigma currency format
- join → N:1 relationship + derived "Order Fact" explore element with
  `[ORDER_FACT/customer_dim/...]` cross-element refs

## Converter

`mcp__sigma-data-model__convert_lookml_to_sigma` with `files=[{name, content}]`
for the model + both view files, empty explore_name/join_strategy/connection_id.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-orders/skilltest_orders.model.lkml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-orders/views/order_fact.view.lkml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-orders/views/customer_dim.view.lkml", "format": "text"},
    {"path": "../../../plugins/looker-to-sigma/skills/looker-to-sigma/fixtures/skilltest-orders/skilltest_orders.dashboard.lookml", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 3,
      "columns": 22,
      "metrics": 3,
      "relationships": 1,
      "warnings": 3,
      "element_names": ["CUSTOMER_DIM", "ORDER_FACT", "Order Fact"],
      "metric_names": ["Total Net Revenue", "Order Count", "Average Order Value"]
    }
  }
}
```
