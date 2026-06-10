#!/usr/bin/env python3
"""qlik-discover — Phase 1 of qlik-to-sigma.

Extracts a Qlik Cloud app's structure via qlik-cli (Engine + REST) into the
JSON that mcp__sigma-data-model__convert_qlik_to_sigma consumes, plus the
sheet/chart inventory, the per-sheet CELL GRID (layout), the app's freshness
metadata, and a Qlik-engine snapshot of the app's KPI totals — everything the
downstream build steps need, with no hand-edits.

    python3 qlik-discover.py --app <appId> [--context <ctx>] [--out discovery] [--skip-eval]

Outputs in --out/:
  script.qvs            raw load script (the data-model source of truth)
  measures.json         master measures  [{title, expr}]
  dimensions.json       master dimensions [{title, expr}]
  charts.json           chart objects: vizType, title, sheet, dims (raw defs +
                        labels + nullSuppression), measures (exprs + labels +
                        Qlik number formats), sort
  layout.json           per-sheet cell grid: [{sheetId, title, rank, columns,
                        rows, cells:[{objectId, type, col, row, colspan, rowspan}]}]
  app-meta.json         REST item record: name, lastReloadTime, hasSectionAccess,
                        isDirectQueryMode — feeds the source-freshness preflight
  snapshot.json         Qlik-engine eval of every sheet KPI expression + Max() of
                        date-ish fact fields — the app's IN-MEMORY totals, used to
                        report staleness vs the live warehouse before any parity
  converter-input.json  ready for convert_qlik_to_sigma (tables + masterMeasures + masterDimensions)

Requires qlik-cli on PATH and an active context (`qlik context use <ctx>`).
Master items are enumerated via a temporary MeasureList/DimensionList object
(create → layout → remove); this briefly saves the app and cleans up after.
All other access is read-only; the app is NEVER reloaded.
"""
import json, os, re, subprocess, sys, argparse, tempfile, secrets, string

def qlik(*args, parse_json=True):
    cmd = ["qlik", *args]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0 and parse_json:
        sys.stderr.write(f"WARN {' '.join(args)} -> {out.stderr[:160]}\n")
    if not parse_json:
        return out.stdout
    try:
        return json.loads(out.stdout or "null")
    except json.JSONDecodeError:
        return None

def tmpid():
    return "disc-" + "".join(secrets.choice(string.ascii_lowercase) for _ in range(8))

def enumerate_master(app, ctx_args, kind):
    """kind: 'measure' or 'dimension'. Returns list of {title, expr}."""
    oid = tmpid()
    if kind == "measure":
        props = {"qInfo": {"qId": oid, "qType": "MeasureList"},
                 "qMeasureListDef": {"qType": "measure",
                     "qData": {"title": "/qMetaDef/title", "expr": "/qMeasure/qDef"}}}
        layout_key, expr_field = "qMeasureList", "expr"
    else:
        props = {"qInfo": {"qId": oid, "qType": "DimensionList"},
                 "qDimensionListDef": {"qType": "dimension",
                     "qData": {"title": "/qMetaDef/title", "expr": "/qDim/qFieldDefs"}}}
        layout_key, expr_field = "qDimensionList", "expr"
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(props, f); f.close()
    subprocess.run(["qlik", "app", "object", "set", f.name, "-a", app, *ctx_args],
                   capture_output=True, text=True)
    lay = qlik("app", "object", "layout", oid, "-a", app, *ctx_args)
    subprocess.run(["qlik", "app", "object", "rm", oid, "-a", app, *ctx_args],
                   capture_output=True, text=True)
    os.unlink(f.name)
    items = ((lay or {}).get(layout_key) or {}).get("qItems", [])
    res = []
    for it in items:
        d = it.get("qData", {})
        e = d.get(expr_field)
        if isinstance(e, list): e = e[0] if e else ""
        res.append({"title": d.get("title") or it.get("qInfo", {}).get("qId"), "expr": e or ""})
    return res

# ---- load-script → tables/fields (best-effort) ----
def parse_script(qvs):
    tables = []
    # Match  Label:\n LOAD <fields> (FROM|RESIDENT|SQL|AUTOGENERATE|INLINE)
    for m in re.finditer(r'(\w+)\s*:\s*\n\s*LOAD\b(.*?)(?:\bFROM\b|\bRESIDENT\b|\bSQL\b|\bAUTOGENERATE\b|\bINLINE\b)',
                         qvs, re.IGNORECASE | re.DOTALL):
        name, body = m.group(1), m.group(2)
        fields = []
        for tok in body.split(","):
            tok = tok.strip().strip(";").strip()
            if not tok: continue
            mm = re.search(r'\bAS\s+"?([A-Za-z0-9_]+)"?\s*$', tok, re.IGNORECASE)  # alias wins
            if mm:
                fields.append(mm.group(1))
            else:
                mm2 = re.match(r'"?([A-Za-z0-9_]+)"?$', tok)
                if mm2: fields.append(mm2.group(1))
        if fields:
            tables.append({"name": name, "noOfRows": 0, "fields": [{"name": f} for f in fields]})
    return tables

def qlik_eval(app, ctx_args, expr):
    """Evaluate one expression via the engine (read-only). Returns the raw value string or None."""
    out = subprocess.run(["qlik", "app", "eval", expr, "-a", app, *ctx_args],
                         capture_output=True, text=True)
    lines = [l for l in out.stdout.splitlines() if l.strip()]
    return lines[1].strip() if out.returncode == 0 and len(lines) >= 2 else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--context")
    ap.add_argument("--out", default="discovery")
    ap.add_argument("--skip-eval", action="store_true",
                    help="skip the Qlik-engine snapshot evals (snapshot.json)")
    a = ap.parse_args()
    ctx = ["--context", a.context] if a.context else []
    os.makedirs(a.out, exist_ok=True)

    # 1) load script
    script = qlik("app", "script", "get", "-a", a.app, *ctx, parse_json=False)
    open(os.path.join(a.out, "script.qvs"), "w").write(script)
    tables = parse_script(script)

    # 2) master measures + dimensions
    measures = enumerate_master(a.app, ctx, "measure")
    dims_raw = enumerate_master(a.app, ctx, "dimension")
    json.dump(measures, open(os.path.join(a.out, "measures.json"), "w"), indent=2)
    json.dump(dims_raw, open(os.path.join(a.out, "dimensions.json"), "w"), indent=2)

    # 3) sheets + chart objects (+ the per-sheet CELL GRID for layout)
    objs = qlik("app", "object", "ls", "-a", a.app, "--json", *ctx) or []
    charts, sheets, obj_sheet = [], [], {}
    all_props = {}
    for o in objs:
        oid = o.get("qId")
        all_props[oid] = qlik("app", "object", "properties", oid, "-a", a.app, *ctx) or {}
    # sheets first, so each chart can be annotated with its sheet
    for o in objs:
        oid, qtype = o.get("qId"), o.get("qType")
        if qtype != "sheet": continue
        props = all_props[oid]
        cells = [{"objectId": c.get("name"), "type": c.get("type"),
                  "col": c.get("col", 0), "row": c.get("row", 0),
                  "colspan": c.get("colspan", 1), "rowspan": c.get("rowspan", 1)}
                 for c in (props.get("cells") or [])]
        for c in cells: obj_sheet[c["objectId"]] = oid
        sheets.append({"sheetId": oid,
                       "title": (props.get("qMetaDef") or {}).get("title") or oid,
                       "rank": props.get("rank", 0),
                       "columns": props.get("columns", 24), "rows": props.get("rows", 12),
                       "cells": cells})
    sheets.sort(key=lambda s: (s["rank"] is None, s["rank"]))
    json.dump(sheets, open(os.path.join(a.out, "layout.json"), "w"), indent=2)

    for o in objs:
        oid, qtype = o.get("qId"), o.get("qType")
        if qtype == "sheet": continue
        props = all_props[oid]
        hc = props.get("qHyperCubeDef", {})
        # Carry the object's sort definition so the workbook build can reproduce it:
        # per-dimension qSortCriterias (qSortByNumeric/qSortByAscii/qSortByExpression),
        # per-measure qSortBy, and the column precedence (qInterColumnSortOrder).
        # Empty lists/{} mean "Qlik default" — the builder should only emit a Sigma
        # sort (xAxis.sort / groupings[0].sort) when one is present.
        sort = {
            "interColumnSortOrder": hc.get("qInterColumnSortOrder") or [],
            "dimensions": [ (dd.get("qDef", {}).get("qSortCriterias") or []) for dd in hc.get("qDimensions", []) ],
            "measures":   [ (mm.get("qSortBy") or {}) for mm in hc.get("qMeasures", []) ],
        }
        qdims, qmeas = hc.get("qDimensions", []), hc.get("qMeasures", [])
        charts.append({
            "id": oid, "vizType": qtype,
            "title": (props.get("qMetaDef") or {}).get("title") or (props.get("title")),
            "sheet": obj_sheet.get(oid),
            "dimensions": [ (dd.get("qDef", {}).get("qFieldDefs") or [dd.get("qLibraryId")]) for dd in qdims ],
            "dimLabels": [ ((dd.get("qDef", {}).get("qFieldLabels") or [None]) or [None])[0] for dd in qdims ],
            "dimNullSuppression": [ bool(dd.get("qNullSuppression")) for dd in qdims ],
            "measures":   [ (mm.get("qDef", {}).get("qDef") or mm.get("qLibraryId")) for mm in qmeas ],
            "measureLabels": [ mm.get("qDef", {}).get("qLabel") for mm in qmeas ],
            "measureFmts": [ (mm.get("qDef", {}).get("qNumFormat") or {}).get("qFmt") for mm in qmeas ],
            "sort": sort,
        })
    json.dump(charts, open(os.path.join(a.out, "charts.json"), "w"), indent=2)

    # 4) app metadata (freshness + security + mode) via the REST item record
    items = qlik("item", "ls", "--resourceType", "app", "--limit", "200", *ctx) or []
    rec = next((i for i in items if i.get("resourceId") == a.app), {})
    app_meta = rec.get("resourceAttributes") or {}
    json.dump(app_meta, open(os.path.join(a.out, "app-meta.json"), "w"), indent=2)

    # 5) Qlik-engine snapshot (source-freshness preflight input): evaluate every
    #    on-sheet KPI expression + Max() of date-ish fact fields IN THE APP's
    #    in-memory data. Comparing these against the live warehouse tells the user
    #    up front whether Qlik is stale ("Sigma will show more data").
    snapshot = {"lastReloadTime": app_meta.get("lastReloadTime"), "kpis": [], "maxDates": []}
    if not a.skip_eval:
        seen = set()
        kpi_like = [c for c in charts if c["sheet"] and c["measures"] and not c["dimensions"]]
        for c in kpi_like:
            expr = c["measures"][0]
            if not expr or expr in seen: continue
            seen.add(expr)
            val = qlik_eval(a.app, ctx, expr)
            snapshot["kpis"].append({"expr": expr, "title": c["title"] or c["measureLabels"][0], "value": val})
        # date-ish fields on the (heuristic) fact table = the table with the most *_KEY fields
        if tables:
            fact = max(tables, key=lambda t: sum(1 for f in t["fields"] if f["name"].upper().endswith("_KEY")))
            datey = [f["name"] for f in fact["fields"] if "DATE" in f["name"].upper()][:2]
            for fld in datey:
                val = qlik_eval(a.app, ctx, f"Max({fld})")
                snapshot["maxDates"].append({"field": fld, "value": val})
    json.dump(snapshot, open(os.path.join(a.out, "snapshot.json"), "w"), indent=2)

    # 6) converter input (feed the Qlik MODEL field names; simple dims are skipped by converter)
    CALC = re.compile(r'^=|\b(If|Sum|Count|Avg|Concat|Year|Month|Day|Left|Right|Upper|Lower|Trim)\s*\(', re.I)
    master_dims = [{"title": d["title"], "fieldDef": d["expr"]} for d in dims_raw if CALC.search(d["expr"] or "")]
    conv = {"appName": app_meta.get("name") or a.app, "tables": tables,
            "masterMeasures": [{"title": m["title"], "qDef": m["expr"]} for m in measures],
            "masterDimensions": master_dims}
    json.dump(conv, open(os.path.join(a.out, "converter-input.json"), "w"), indent=2)

    on_sheet = sum(1 for c in charts if c["sheet"])
    print(f"tables={len(tables)} measures={len(measures)} dimensions={len(dims_raw)} "
          f"(calc={len(master_dims)}) charts={len(charts)} (on-sheet={on_sheet}) sheets={len(sheets)} -> {a.out}/")
    if snapshot["kpis"]:
        print("snapshot:", "; ".join(f"{k['title']}={k['value']}" for k in snapshot["kpis"][:6]))
    print(f"lastReloadTime={app_meta.get('lastReloadTime', '?')}")
    print("Next: scripts/migrate-qlik.rb runs the whole pipeline from this directory in one command.")

if __name__ == "__main__":
    main()
