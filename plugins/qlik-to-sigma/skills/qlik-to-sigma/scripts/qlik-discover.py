#!/usr/bin/env python3
"""qlik-discover — Phase 1 of qlik-to-sigma.

Extracts a Qlik Cloud app's structure via qlik-cli (Engine + REST) into the
JSON that mcp__sigma-data-model__convert_qlik_to_sigma consumes, plus the
sheet/chart inventory used to rebuild the Sigma workbook.

    python3 qlik-discover.py --app <appId> [--context <ctx>] [--out discovery]

Outputs in --out/:
  script.qvs            raw load script (the data-model source of truth)
  measures.json         master measures  [{title, qDef}]
  dimensions.json       master dimensions [{title, fieldDef, isCalc}]
  charts.json           sheets + chart objects (vizType, dims, measures)
  converter-input.json  ready for convert_qlik_to_sigma (tables + masterMeasures + masterDimensions)

Requires qlik-cli on PATH and an active context (`qlik context use <ctx>`).
Master items are enumerated via a temporary MeasureList/DimensionList object
(create → layout → remove); this briefly saves the app and cleans up after.
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--context")
    ap.add_argument("--out", default="discovery")
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

    # 3) sheets + chart objects
    objs = qlik("app", "object", "ls", "-a", a.app, "--json", *ctx) or []
    charts = []
    for o in objs:
        oid, qtype = o.get("qId"), o.get("qType")
        props = qlik("app", "object", "properties", oid, "-a", a.app, *ctx) or {}
        hc = props.get("qHyperCubeDef", {})
        # Carry the object's sort definition so the workbook build can reproduce it:
        # per-dimension qSortCriterias (qSortByNumeric/qSortByAscii/qSortByExpression),
        # per-measure qSortBy, and the column precedence (qInterColumnSortOrder).
        # Empty lists/{} mean "Qlik default" — the builder should only emit a Sigma
        # sort (xAxis.sort / element sort:[{columnId,direction}]) when one is present.
        sort = {
            "interColumnSortOrder": hc.get("qInterColumnSortOrder") or [],
            "dimensions": [ (dd.get("qDef", {}).get("qSortCriterias") or []) for dd in hc.get("qDimensions", []) ],
            "measures":   [ (mm.get("qSortBy") or {}) for mm in hc.get("qMeasures", []) ],
        }
        charts.append({
            "id": oid, "vizType": qtype,
            "title": (props.get("qMetaDef") or {}).get("title") or (props.get("title")),
            "dimensions": [ (dd.get("qDef", {}).get("qFieldDefs") or [dd.get("qLibraryId")]) for dd in hc.get("qDimensions", []) ],
            "measures":   [ (mm.get("qDef", {}).get("qDef") or mm.get("qLibraryId")) for mm in hc.get("qMeasures", []) ],
            "sort": sort,
        })
    json.dump(charts, open(os.path.join(a.out, "charts.json"), "w"), indent=2)

    # 4) converter input (feed the Qlik MODEL field names; simple dims are skipped by converter)
    CALC = re.compile(r'^=|\b(If|Sum|Count|Avg|Concat|Year|Month|Day|Left|Right|Upper|Lower|Trim)\s*\(', re.I)
    master_dims = [{"title": d["title"], "fieldDef": d["expr"]} for d in dims_raw if CALC.search(d["expr"] or "")]
    conv = {"appName": a.app, "tables": tables,
            "masterMeasures": [{"title": m["title"], "qDef": m["expr"]} for m in measures],
            "masterDimensions": master_dims}
    json.dump(conv, open(os.path.join(a.out, "converter-input.json"), "w"), indent=2)

    print(f"tables={len(tables)} measures={len(measures)} dimensions={len(dims_raw)} "
          f"(calc={len(master_dims)}) charts={len(charts)} -> {a.out}/")
    print("Next: feed converter-input.json to convert_qlik_to_sigma, then scripts/build-sigma-dm.py")

if __name__ == "__main__":
    main()
