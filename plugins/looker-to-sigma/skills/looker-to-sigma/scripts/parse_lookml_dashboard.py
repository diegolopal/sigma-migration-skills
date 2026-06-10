#!/usr/bin/env python3
"""Offline path: parse a Looker `.dashboard.lookml` file into the normalized
Dashboard contract (refs/dashboard-contract.md). Dashboard LookML is YAML.

Live path (later): a fetch-looker-dashboard script hits the Looker REST API
(`GET /dashboards/{id}` + `dashboard_layouts`) and emits the SAME contract, so
the workbook builder stays source-agnostic.

Usage:
    python3 parse_lookml_dashboard.py <file.dashboard.lookml> [--out contract.json]
"""
import argparse, json, sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


def norm_element(el):
    return {
        "name": el.get("name") or el.get("title"),
        "title": el.get("title"),
        "tileType": el.get("type"),
        "model": el.get("model"),
        "explore": el.get("explore"),
        "fields": el.get("fields") or [],
        "pivots": el.get("pivots") or [],
        # tile-level hard filters {field: expr}
        "filters": el.get("filters") or {},
        "sorts": el.get("sorts") or [],
        "limit": el.get("limit"),
        # which dashboard filters this tile obeys: {FilterName: field}
        "listen": el.get("listen") or {},
        # client-side table calcs / custom measures → workbook formulas
        "dynamicFields": el.get("dynamic_fields") or [],
        "noteText": el.get("note_text"),
        "subtitleText": el.get("subtitle_text"),
        # single_value comparison (Sigma KPI spec has no comparison slot → warn)
        "showComparison": bool(el.get("show_comparison")),
        "comparisonType": el.get("comparison_type"),
        # newspaper grid units (LookML uses `col`; API uses `column` — normalize to col)
        "layout": {
            "row": el.get("row", 0), "col": el.get("col", 0),
            "width": el.get("width", 8), "height": el.get("height", 6),
        },
    }


def norm_filter(f):
    return {
        "name": f.get("name"),
        "title": f.get("title") or f.get("name"),
        "type": f.get("type"),                # date_filter | field_filter | ...
        "model": f.get("model"),
        "explore": f.get("explore"),
        "field": f.get("field"),              # view.field this filter binds to
        "defaultValue": f.get("default_value"),
        "allowMultiple": bool(f.get("allow_multiple_values")),
        "listensToFilters": f.get("listens_to_filters") or [],
    }


def parse(path):
    with open(path) as fh:
        docs = yaml.safe_load(fh)
    # A .dashboard.lookml is a YAML list of dashboards (usually one).
    if isinstance(docs, dict):
        docs = [docs]
    out = []
    for d in docs:
        out.append({
            "id": d.get("dashboard"),
            "title": d.get("title"),
            "layoutMode": d.get("layout", "newspaper"),
            "source": "lookml",
            "lookmlLinkId": None,
            "filters": [norm_filter(f) for f in (d.get("filters") or [])],
            "elements": [norm_element(e) for e in (d.get("elements") or [])],
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--out")
    a = ap.parse_args()
    dashboards = parse(a.file)
    js = json.dumps(dashboards if len(dashboards) > 1 else dashboards[0], indent=2)
    if a.out:
        open(a.out, "w").write(js)
        d0 = dashboards[0]
        print(f"wrote {a.out}: {d0['title']} — {len(d0['elements'])} elements, "
              f"{len(d0['filters'])} filters, layout={d0['layoutMode']}")
    else:
        print(js)


if __name__ == "__main__":
    main()
