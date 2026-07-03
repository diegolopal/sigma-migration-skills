#!/usr/bin/env python3
"""Generate a Sigma workbook YAML spec from a field mapping.

Usage:
    python3 build_workbook_spec.py \
        --dm-id <data_model_id> \
        --element-id <visible_element_id> \
        --element-name "Salesloft Users Current State" \
        --mapping mapping.json \
        --page-name "My Report" \
        --output /tmp/workbook-spec.yaml

mapping.json format:
[
  {"id": "c01", "formula": "[Element/Column Name]", "name": "Display Label", "in_order": true},
  {"id": "c02", "formula": "[Element/Rel/Column]", "name": "Via Relationship", "in_order": true},
  {"id": "c03", "formula": "[Element/Team ID]", "name": "Team ID", "in_order": false, "control": "number"}
]

Fields with "control": "number" get a numeric control created.
Fields with "in_order": false are included but not shown in the table order.
Boolean filters are NEVER generated (API limitation -- add in Sigma UI).

Requires: No env vars (generates a static YAML file).
"""

import argparse
import json
import sys


SPEC_TEMPLATE = """schemaVersion: 1
pages:
  - id: {page_id}
    name: {page_name}
    elements:
      - id: mainTable
        kind: table
        name: {table_name}
        source:
          dataModelId: {dm_id}
          elementId: {element_id}
          kind: data-model
        columns:
{columns_yaml}
        order:
{order_yaml}
{controls_yaml}
layout: |
  <?xml version="1.0" encoding="utf-8"?>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">
{layout_yaml}
  </Page>
"""


def build_spec(dm_id, element_id, element_name, mapping, page_name, page_id):
    columns_lines = []
    order_lines = []
    controls = []

    for field in mapping:
        col_yaml = f'          - id: {field["id"]}\n'
        col_yaml += f'            formula: "{field["formula"]}"\n'
        col_yaml += f'            name: {field["name"]}'
        columns_lines.append(col_yaml)

        if field.get("in_order", True):
            order_lines.append(f"          - {field['id']}")

        if field.get("control") == "number":
            controls.append(field)

    columns_yaml = "\n".join(columns_lines)
    order_yaml = "\n".join(order_lines)

    # Build controls YAML
    controls_yaml = ""
    if controls:
        ctrl_parts = []
        for i, ctrl in enumerate(controls):
            ctrl_id = f"ctrl{i}"
            ctrl_parts.append(
                f"      - kind: control\n"
                f"        controlId: {ctrl['id']}-filter\n"
                f"        id: {ctrl_id}\n"
                f"        name: {ctrl['name']}\n"
                f"        filters:\n"
                f"          - source:\n"
                f"              kind: table\n"
                f"              elementId: mainTable\n"
                f"            columnId: {ctrl['id']}\n"
                f"        controlType: number\n"
                f"        mode: '='\n"
                f"        includeNulls: when-no-value-is-selected"
            )
        controls_yaml = "\n".join(ctrl_parts)

    # Build layout
    layout_lines = []
    row = 1
    if controls:
        for i in range(len(controls)):
            col_start = 1 + i * 6
            col_end = col_start + 6
            layout_lines.append(
                f'    <LayoutElement elementId="ctrl{i}" gridColumn="{col_start} / {col_end}" gridRow="1 / 3"/>'
            )
        row = 3
    layout_lines.append(
        f'    <LayoutElement elementId="mainTable" gridColumn="1 / 25" gridRow="{row} / {row + 22}"/>'
    )
    layout_yaml = "\n".join(layout_lines)

    spec = SPEC_TEMPLATE.format(
        page_id=page_id,
        page_name=page_name,
        table_name=page_name,
        dm_id=dm_id,
        element_id=element_id,
        columns_yaml=columns_yaml,
        order_yaml=order_yaml,
        controls_yaml=controls_yaml,
        layout_yaml=layout_yaml,
    )

    return spec


def main():
    parser = argparse.ArgumentParser(description="Build Sigma workbook spec YAML")
    parser.add_argument("--dm-id", required=True, help="Sigma Data Model ID")
    parser.add_argument("--element-id", required=True, help="Visible element ID")
    parser.add_argument("--element-name", required=True, help="Element display name")
    parser.add_argument("--mapping", required=True, help="JSON file with field mapping")
    parser.add_argument("--page-name", default="Report", help="Page/workbook name")
    parser.add_argument("--page-id", default="page1", help="Page ID (use actual from created workbook)")
    parser.add_argument("--output", default="/tmp/workbook-spec.yaml", help="Output YAML path")
    args = parser.parse_args()

    with open(args.mapping) as f:
        mapping = json.load(f)

    spec = build_spec(
        dm_id=args.dm_id,
        element_id=args.element_id,
        element_name=args.element_name,
        mapping=mapping,
        page_name=args.page_name,
        page_id=args.page_id,
    )

    with open(args.output, "w") as f:
        f.write(spec)

    print(f"Spec written to: {args.output}")
    print(f"\nNOTE: The following must be done manually in the Sigma UI:")
    print(f"  - Boolean filters (Active=True, Deleted=False, etc.)")
    print(f"  - Text/list controls (Team Name, etc.)")
    print(f"  - VARIANT column extraction (Pollers, etc.)")


if __name__ == "__main__":
    main()
