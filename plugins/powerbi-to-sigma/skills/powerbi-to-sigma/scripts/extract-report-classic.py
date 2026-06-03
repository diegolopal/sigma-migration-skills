#!/usr/bin/env python3
"""extract-report-classic.py — adapter for the CLASSIC single-file report.json.

Some Power BI reports come back from Fabric getDefinition as the legacy
single `report.json` (top-level `sections[]` with `visualContainers[]`, each
carrying a `config` JSON string) rather than the new exploded PBIR
(`definition/pages/<pg>/visuals/<id>/visual.json`). extract-pbir.py only
handles the new layout; this adapter normalizes the classic shape into the
SAME signals.json schema so build-workbook-from-pbir.rb can consume it.

Classic report.json shape:
  sections[] : { name, displayName, width, height, visualContainers[] }
    visualContainers[] : { x, y, width, height, z, config(JSON string) }
      config : { name, singleVisual:{ visualType, projections:{Role:[{queryRef}]},
                                      objects:{ title[], general[] (textbox) } } }

Usage:
  python3 extract-report-classic.py --report-json /tmp/pbir-orders/report.json \
      --out /tmp/pbir-orders/signals.json
"""
import argparse, json, sys

# Same visualType -> Sigma element kind table as extract-pbir.py.
VISUAL_KIND = {
    "card": "kpi", "multiRowCard": "kpi", "kpi": "kpi", "gauge": "kpi",
    "textbox": "text", "actionButton": "text",
    "lineChart": "line", "areaChart": "area", "stackedAreaChart": "area",
    "barChart": "bar", "clusteredBarChart": "bar", "stackedBarChart": "bar",
    "columnChart": "bar", "clusteredColumnChart": "bar", "stackedColumnChart": "bar",
    "hundredPercentStackedColumnChart": "bar",
    "lineClusteredColumnComboChart": "combo", "lineStackedColumnComboChart": "combo",
    "pieChart": "pie", "donutChart": "donut", "scatterChart": "scatter",
    "tableEx": "table", "pivotTable": "pivot-table", "matrix": "pivot-table",
    "slicer": "control",
    "map": "bar", "filledMap": "bar", "shapeMap": "bar", "azureMap": "bar",
}

# *Bar* = horizontal, *Column* = vertical (Sigma default). Sigma's bar-chart
# `orientation` accepts only "horizontal"; vertical = omit the field.
HBAR_TYPES = {"barChart", "clusteredBarChart", "stackedBarChart",
              "hundredPercentStackedBarChart"}

# Geo/map visuals bind Series(=location dim) + Size(=measure). The bar branch of
# the builder reads Category/Axis/X (dim) and Y/Values (measure), so remap.
ROLE_REMAP = {
    "Series": "Category",
    "Size": "Y",
    "Location": "Category",
    "Latitude": "Category",
}


def _projections(sv):
    out = {}
    for role, items in (sv.get("projections", {}) or {}).items():
        refs = [it.get("queryRef") for it in items if isinstance(it, dict) and it.get("queryRef")]
        if refs:
            out[ROLE_REMAP.get(role, role)] = refs
    return out


def _title(sv):
    for it in sv.get("objects", {}).get("title", []):
        props = it.get("properties", {})
        show = props.get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        t = props.get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
        if t and show != "false":
            return t.strip("'")
    return None


def _textbox_body(sv):
    for para in sv.get("objects", {}).get("general", []):
        paras = para.get("properties", {}).get("paragraphs", [])
        for p in paras:
            for run in p.get("textRuns", []):
                v = run.get("value")
                if v:
                    return v
    return None


def extract(report):
    out_pages = []
    for s in report.get("sections", []):
        visuals = []
        for vc in s.get("visualContainers", []):
            cfg = json.loads(vc.get("config", "{}"))
            sv = cfg.get("singleVisual", {})
            vt = sv.get("visualType", "unknown")
            # position: prefer vc top-level x/y/w/h, fall back to config layouts
            x = vc.get("x"); y = vc.get("y"); w = vc.get("width"); h = vc.get("height")
            if x is None:
                pos = (cfg.get("layouts", [{}])[0] or {}).get("position", {})
                x, y, w, h = pos.get("x", 0), pos.get("y", 0), pos.get("width", 0), pos.get("height", 0)
            rec = {
                "visual_id": cfg.get("name", f"{s.get('name')}-{len(visuals)}"),
                "visual_type": vt,
                "title": _title(sv),
                "sigma_kind": VISUAL_KIND.get(vt, "bar"),
                "orientation": "horizontal" if vt in HBAR_TYPES else None,
                "x": x or 0, "y": y or 0, "w": w or 0, "h": h or 0,
                "z": vc.get("z", 0),
                "parent_group": None,
                "bindings": _projections(sv),
                "formats": {},
            }
            if rec["sigma_kind"] == "text":
                rec["text"] = _textbox_body(sv)
            visuals.append(rec)
        visuals.sort(key=lambda r: (r["y"], r["x"]))
        out_pages.append({
            "page_id": s.get("name"),
            "page_title": s.get("displayName", s.get("name")),
            "page_w": s.get("width", 1280),
            "page_h": s.get("height", 720),
            "visuals": visuals,
        })
    return {"source": "report.json-classic", "pages": out_pages}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report-json", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    report = json.load(open(a.report_json))
    signals = extract(report)
    json.dump(signals, open(a.out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[classic] {len(signals['pages'])} page(s), {nvis} visual(s) -> {a.out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {v['visual_type']:>14} -> {v['sigma_kind']:<6} {v['bindings']}", file=sys.stderr)


if __name__ == "__main__":
    main()
