#!/usr/bin/env python3
"""build-sigma-workbook — Phase 4 of qlik-to-sigma: author + POST the Sigma
workbook from the DISCOVERY artifacts (charts.json + layout.json + denorm.json).
No baked-in sheets, charts, or column lists — everything comes from the app.

    python3 build-sigma-workbook.py \
      --charts WORK/charts.json --layout WORK/layout.json --denorm WORK/denorm.json \
      --dm-id <dataModelId> --denorm-element-id <elementId> \
      --name "Retail Orders" [--folder <folderId>] \
      [--dry-run] [--out wb-result.json] [--spec-out wb-spec.json] \
      [--layout-out layout.xml] [--element-map element-map.json]

What it builds:
  - A hidden "Data" page with one master table (every denorm column) sourced
    from the data-model denorm element — the single source for every chart.
  - One Sigma page PER QLIK SHEET (layout.json order), each chart placed by
    mapping the Qlik sheet's cell grid (col/row/colspan/rowspan on a
    columns×rows grid, default 24×12) 1:1 onto Sigma's 24-col grid with a
    row-scale of 2 (min — so KPI titles and axis labels render; KPIs are
    bumped to ≥5 grid rows, the title-clip threshold).
  - Chart kinds from the Qlik vizType (barchart/linechart/piechart/combochart/
    table/kpi). `auto-chart` is resolved by shape: no dims → KPI; ≥2 dims →
    grouped table; 1 temporal dim → line; else bar.
  - Qlik measure expressions are translated token-wise (Sum/Avg/Min/Max/Count,
    Count(DISTINCT …) → CountDistinct, simple Set Analysis {<F={v}>} →
    Sum(If(...)), arithmetic combinations like Sum(a)/Sum(b)). Untranslatable
    charts are skipped + reported (gap-scout them).
  - Qlik qNumFormat → Sigma formatString ($#,##0 → $,.0f, #0.0% → ,.1%, …).
  - Qlik's associative model hides unmatched/null dimension rows
    (qNullSuppression). Faithful default: a hidden Not(IsNull(dim)) bool col +
    include-[true] list filter per suppressed dim. QLIK_KEEP_UNMATCHED=1 keeps
    the null rows instead (warehouse-faithful).
  - Sorts: an explicit Qlik sort (qSortCriterias / qSortBy / interColumnSortOrder)
    wins; else tables + bar charts default to first-measure-descending (Qlik's
    auto-chart behavior). Grouped-table sort nests INSIDE groupings[0].sort —
    element-level sort 400s on grouped tables (verified 2026-06-10).

Outputs: wb-result.json {workbookId, pages, elements, skipped}, layout XML
(multi-<Page> fragment for put-layout.rb), element-map.json (Sigma element ↔
Qlik object, incl. dims/measures — feeds the Phase-6 freshness + bucket parity).
With --dry-run nothing is POSTed.

Env (live mode): SIGMA_BASE_URL + SIGMA_API_TOKEN.
"""
import json, os, re, sys, argparse, urllib.request

MASTER_ID, MASTER = "m-master", "Master"
KEEP_UNMATCHED = os.environ.get("QLIK_KEEP_UNMATCHED", "") == "1"
ROW_SCALE = 2          # min row-scale; Qlik rows are ~3x shorter than Sigma's
KPI_MIN_ROWS = 5       # Sigma kpi-chart clips its title below ~5 grid rows
TEMPORAL = re.compile(r"DATE|MONTH|YEAR|QUARTER|WEEK|DAY", re.I)
NATIVE = {"barchart": "bar-chart", "linechart": "line-chart", "piechart": "pie-chart",
          "combochart": "combo-chart", "scatterplot": "scatter-chart",
          "table": "table", "kpi": "kpi-chart", "pivot-table": "pivot-table"}

_ids = {}
def nid(prefix):
    _ids[prefix] = _ids.get(prefix, 0) + 1
    return f"{prefix}{_ids[prefix]}"

def api_post(path, body):
    BASE = os.environ["SIGMA_BASE_URL"]; TOK = os.environ["SIGMA_API_TOKEN"]
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": "Bearer " + TOK, "Content-Type": "application/json",
                 "Accept": "application/json"})
    try:
        return urllib.request.urlopen(req).read().decode()
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:800], file=sys.stderr); raise

def sigma_fmt(qfmt, name=""):
    """Qlik qNumFormat.qFmt -> Sigma formatString. Falls back to a name heuristic."""
    if qfmt:
        dec = 0
        if "." in qfmt:
            dec = len(re.sub(r"[^0#]", "", qfmt.split(".", 1)[1]))
        if "%" in qfmt: return {"kind": "number", "formatString": f",.{dec}%"}
        pre = "$" if qfmt.lstrip().startswith("$") else ""
        return {"kind": "number", "formatString": f"{pre},.{dec}f"}
    if re.search(r"%|margin|rate", name, re.I): return {"kind": "number", "formatString": ",.1%"}
    if re.search(r"revenue|profit|amount|value|cost|price", name, re.I):
        return {"kind": "number", "formatString": "$,.0f"}
    return {"kind": "number", "formatString": ",.0f"}

class Resolver:
    """Raw Qlik field name -> master-column display name (via the denorm element)."""
    def __init__(self, denorm_cols):
        self.raw_to_disp = {}
        for dn, raw in denorm_cols:
            self.raw_to_disp[raw.upper()] = dn
            self.raw_to_disp[dn.upper().replace(" ", "_")] = dn
    def __call__(self, qlik_name):
        if not qlik_name: return None
        k = str(qlik_name).upper()
        return self.raw_to_disp.get(k) or self.raw_to_disp.get(k.replace(" ", "_"))

def translate_measure(expr, resolve):
    """Qlik measure expression -> Sigma formula over the master, or None.
    Token-wise: handles aggregates, Count(DISTINCT), simple Set Analysis, and
    arithmetic combinations of those (Sum(a)/Sum(b), Sum(a)/Count(DISTINCT b))."""
    e = str(expr or "").strip().lstrip("=").strip()
    if not e: return None
    unresolved = []
    def ref(f):
        d = resolve(f)
        if d is None: unresolved.append(f)
        return f"[{MASTER}/{d}]"
    def set_analysis(m):
        agg, cf, val, xf = m.group(1).capitalize(), m.group(2), m.group(3).strip(), m.group(4)
        val = val.strip("'\"")
        lit = val if re.fullmatch(r"-?\d+(\.\d+)?", val) else f'"{val}"'
        inner = f"If({ref(cf)} = {lit}, {ref(xf)})"
        return f"CountDistinct({inner})" if agg == "Count" and m.group(0).upper().find("DISTINCT") >= 0 \
            else f"{agg}({inner})"
    # 1) simple Set Analysis  Agg({<F={v}>} [DISTINCT] X)
    e = re.sub(r"\b(Sum|Avg|Min|Max|Count)\s*\(\s*\{\s*<\s*([A-Za-z0-9_]+)\s*=\s*\{([^}]*)\}\s*>\s*\}\s*(?:DISTINCT\s+)?([A-Za-z0-9_]+)\s*\)",
               set_analysis, e, flags=re.I)
    # 2) Count(DISTINCT X)
    e = re.sub(r"\bCount\s*\(\s*DISTINCT\s+([A-Za-z0-9_]+)\s*\)",
               lambda m: f"CountDistinct({ref(m.group(1))})", e, flags=re.I)
    # 3) plain Agg(FIELD)
    e = re.sub(r"\b(Sum|Avg|Min|Max|Count)\s*\(\s*([A-Za-z0-9_]+)\s*\)",
               lambda m: f"{m.group(1).capitalize()}({ref(m.group(2))})", e, flags=re.I)
    if unresolved: return None
    # anything left that looks like a bare Qlik field/function = untranslated
    leftovers = re.sub(r"\[[^\]]*\]|CountDistinct|Sum|Avg|Min|Max|Count|If", "", e)
    if re.search(r"[A-Za-z_]{2,}", leftovers): return None
    return e

def qlik_sort(c, dim_ids, meas_ids):
    """Explicit Qlik sort -> (columnId, direction) or None."""
    s = c.get("sort") or {}
    order = s.get("interColumnSortOrder") or []
    ndims = len(dim_ids)
    for idx in order:
        if idx < ndims and idx < len(s.get("dimensions", [])):
            crit = (s["dimensions"][idx] or [{}])[0] if s["dimensions"][idx] else {}
            if crit.get("qSortByNumeric") in (1, -1):
                return dim_ids[idx], "ascending" if crit["qSortByNumeric"] == 1 else "descending"
            if crit.get("qSortByAscii") in (1, -1):
                return dim_ids[idx], "ascending" if crit["qSortByAscii"] == 1 else "descending"
        elif idx >= ndims and (idx - ndims) < len(meas_ids):
            mb = (s.get("measures") or [{}] * len(meas_ids))[idx - ndims] or {}
            if mb.get("qSortByNumeric") in (1, -1):
                return meas_ids[idx - ndims], "ascending" if mb["qSortByNumeric"] == 1 else "descending"
    return None

def build_element(c, resolve, warnings):
    """One Qlik chart object -> one Sigma element (or None + warning)."""
    title = c.get("title") or c.get("vizType")
    dims_raw = [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])]
    dim_disp = [resolve(d) for d in dims_raw]
    labels = c.get("dimLabels") or [None] * len(dims_raw)
    nsup = c.get("dimNullSuppression") or [True] * len(dims_raw)
    mexprs = c.get("measures") or []
    mlabels = c.get("measureLabels") or [None] * len(mexprs)
    mfmts = c.get("measureFmts") or [None] * len(mexprs)

    # kind
    vt = c.get("vizType")
    if vt == "auto-chart":
        if not dims_raw and mexprs: kind = "kpi-chart"
        elif len(dims_raw) >= 2:    kind = "table"
        elif dims_raw and TEMPORAL.search(dims_raw[0] or ""): kind = "line-chart"
        else: kind = "bar-chart"
    else:
        kind = NATIVE.get(vt)
        if kind is None:
            if not (dims_raw and mexprs):
                warnings.append(f"skip '{title}' ({vt}): no native Sigma kind"); return None
            kind = "bar-chart"
            warnings.append(f"'{title}' ({vt}) approximated as bar-chart")

    if dims_raw and any(d is None for d in dim_disp):
        warnings.append(f"skip '{title}': dim(s) {dims_raw} not on the denorm element"); return None

    cols, mids, mnames = [], [], []
    for i, mexpr in enumerate(mexprs):
        f = translate_measure(mexpr, resolve)
        if f is None:
            warnings.append(f"'{title}': measure not translated: {mexpr}")
            continue
        mname = mlabels[i] or (title if kind == "kpi-chart" else f"Measure {i+1}")
        cid = nid("y")
        cols.append({"id": cid, "formula": f, "name": mname, "format": sigma_fmt(mfmts[i], mname)})
        mids.append(cid); mnames.append(mname)
    if not mids:
        warnings.append(f"skip '{title}': no translatable measures"); return None

    el = {"id": "el-" + re.sub(r"[^a-z0-9]", "", str(c["id"]).lower()),
          "kind": kind, "name": title,
          "source": {"elementId": MASTER_ID, "kind": "table"}}

    if kind == "kpi-chart":
        el["columns"] = cols
        el["value"] = {"columnId": mids[0]}   # value.columnId, NOT value.id (live API 400s)
        return el

    dim_ids = []
    for i, d in enumerate(dim_disp):
        cid = nid("x")
        cols.insert(i, {"id": cid, "formula": f"[{MASTER}/{d}]", "name": labels[i] or d})
        dim_ids.append(cid)
    el["columns"] = cols

    # associative-model null suppression (per suppressed dim)
    filters = []
    if not KEEP_UNMATCHED:
        for i, d in enumerate(dim_disp):
            if not nsup[i]: continue
            b = nid("nn")
            hidden_col = {"id": b, "formula": f"Not(IsNull([{MASTER}/{d}]))",
                          "name": f"{labels[i] or d} Matched"}
            if kind == "table": hidden_col["hidden"] = True
            el["columns"].append(hidden_col)
            filters.append({"id": nid("f"), "columnId": b, "kind": "list",
                            "mode": "include", "values": [True]})
    if filters: el["filters"] = filters

    sort = qlik_sort(c, dim_ids, mids)
    if sort is None and kind in ("table", "bar-chart") and mids:
        sort = (mids[0], "descending")   # Qlik auto-chart default: by measure, desc

    if kind == "table":
        # Aggregating table needs explicit groupings or it renders 1 row/source row
        el["groupings"] = [{"id": nid("g"), "groupBy": dim_ids, "calculations": mids}]
        if sort: el["groupings"][0]["sort"] = [{"columnId": sort[0], "direction": sort[1]}]
        return el
    if kind == "pie-chart":
        el["value"] = {"id": mids[0]}; el["color"] = {"id": dim_ids[0]}
        el["dataLabel"] = {"labels": "shown"}
        return el
    if kind == "combo-chart":
        y = [mids[0]] + [{"columnId": m, "type": "line"} for m in mids[1:]]
        el["xAxis"] = {"columnId": dim_ids[0]}; el["yAxis"] = {"columnIds": y}
        return el
    # bar / line / scatter
    el["xAxis"] = {"columnId": dim_ids[0]}
    el["yAxis"] = {"columnIds": mids}
    if sort: el["xAxis"]["sort"] = {"by": sort[0], "direction": sort[1]}
    if kind == "bar-chart": el["dataLabel"] = {"labels": "shown"}
    return el

def grid_layout(page_id, sheet, placed):
    """Map the Qlik sheet cell grid onto Sigma's 24-col grid (1-based lines)."""
    qcols = sheet.get("columns") or 24
    lines = [f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">']
    for cell, el in placed:
        c0 = round(cell["col"] * 24 / qcols) + 1
        c1 = round((cell["col"] + cell["colspan"]) * 24 / qcols) + 1
        r0 = cell["row"] * ROW_SCALE + 1
        r1 = (cell["row"] + cell["rowspan"]) * ROW_SCALE + 1
        if el["kind"] == "kpi-chart" and (r1 - r0) < KPI_MIN_ROWS:
            r1 = r0 + KPI_MIN_ROWS
        lines.append(f'  <LayoutElement elementId="{el["id"]}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>')
    lines.append("</Page>")
    return "\n".join(lines)

def auto_layout(page_id, elems):
    """Fallback when no layout.json: KPIs across the top, charts 2-wide below."""
    kpis = [e for e in elems if e["kind"] == "kpi-chart"]
    charts = [e for e in elems if e["kind"] != "kpi-chart"]
    lines = [f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">']
    if kpis:
        w = 24 // len(kpis)
        for i, e in enumerate(kpis):
            c0 = 1 + i * w; c1 = c0 + w if i < len(kpis) - 1 else 25
            lines.append(f'  <LayoutElement elementId="{e["id"]}" gridColumn="{c0} / {c1}" gridRow="1 / 6"/>')
    row = 6
    for i in range(0, len(charts), 2):
        pair = charts[i:i + 2]
        for j, e in enumerate(pair):
            c0 = 1 if j == 0 else 13; c1 = 13 if (j == 0 and len(pair) > 1) else 25
            lines.append(f'  <LayoutElement elementId="{e["id"]}" gridColumn="{c0} / {c1}" gridRow="{row} / {row + 11}"/>')
        row += 11
    lines.append("</Page>")
    return "\n".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--charts", required=True)
    ap.add_argument("--layout")
    ap.add_argument("--denorm", required=True)
    ap.add_argument("--dm-id", required=True)
    ap.add_argument("--denorm-element-id", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--folder")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", default="wb-result.json")
    ap.add_argument("--spec-out", default="wb-spec.json")
    ap.add_argument("--layout-out", default="layout.xml")
    ap.add_argument("--element-map", default="element-map.json")
    a = ap.parse_args()

    charts = {c["id"]: c for c in json.load(open(a.charts))}
    sheets = json.load(open(a.layout)) if a.layout and os.path.exists(a.layout) else []
    denorm = json.load(open(a.denorm))["element"]
    denorm_cols = [(c["name"], (re.search(r"\[Custom SQL/(.+)\]", c["formula"]) or [None, c["name"]])[1])
                   for c in denorm["columns"]]
    resolve = Resolver(denorm_cols)

    master = {"id": MASTER_ID, "name": MASTER, "kind": "table",
              "source": {"dataModelId": a.dm_id, "elementId": a.denorm_element_id, "kind": "data-model"},
              "columns": [{"id": f"o{i}", "name": dn, "formula": f"[Custom SQL/{dn}]"}
                          for i, (dn, _raw) in enumerate(denorm_cols)]}

    warnings, pages, layout_pages, emap = [], [], [], []
    layout_pages.append(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-data">\n'
                        f'  <LayoutElement elementId="{MASTER_ID}" gridColumn="1 / 25" gridRow="1 / 15"/>\n</Page>')
    pages.append({"id": "page-data", "name": "Data", "elements": [master]})

    CHARTY = {"kpi", "auto-chart", "barchart", "linechart", "piechart", "combochart",
              "scatterplot", "table", "pivot-table"}
    if sheets:
        for si, sheet in enumerate(sheets):
            pid = f"pg-{si + 1}"
            elems, placed = [], []
            for cell in sorted(sheet["cells"], key=lambda c: (c["row"], c["col"])):
                c = charts.get(cell["objectId"])
                if c is None: continue
                if c["vizType"] not in CHARTY and not (c.get("measures") or c.get("dimensions")):
                    warnings.append(f"skip '{cell['objectId']}' ({c['vizType']}): not a chart"); continue
                el = build_element(c, resolve, warnings)
                if el is None: continue
                elems.append(el); placed.append((cell, el))
                emap.append({"elementId": el["id"], "pageId": pid, "kind": el["kind"],
                             "name": el["name"], "valueColumnName": el["columns"][0].get("name"),
                             "qlik": {"objectId": c["id"],
                                      "dims": [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])],
                                      "measures": c.get("measures") or [],
                                      "nullSuppression": c.get("dimNullSuppression") or []}})
            if not elems: continue
            pages.append({"id": pid, "name": sheet["title"], "elements": elems})
            layout_pages.append(grid_layout(pid, sheet, placed))
    else:
        # no sheet layout discovered — build every dim+measure chart, auto-layout
        pid, elems = "pg-1", []
        for c in charts.values():
            if not (c.get("measures")): continue
            el = build_element(c, resolve, warnings)
            if el is None: continue
            elems.append(el)
            emap.append({"elementId": el["id"], "pageId": pid, "kind": el["kind"],
                         "name": el["name"], "valueColumnName": el["columns"][0].get("name"),
                         "qlik": {"objectId": c["id"],
                                  "dims": [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])],
                                  "measures": c.get("measures") or [],
                                  "nullSuppression": c.get("dimNullSuppression") or []}})
        pages.append({"id": pid, "name": "Overview", "elements": elems})
        layout_pages.append(auto_layout(pid, [{"id": e["id"], "kind": e["kind"]} for e in elems]))

    spec = {"name": a.name, "schemaVersion": 1, "pages": pages}
    if a.folder: spec["folderId"] = a.folder
    json.dump(spec, open(a.spec_out, "w"), indent=2)
    open(a.layout_out, "w").write('<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(layout_pages))
    json.dump(emap, open(a.element_map, "w"), indent=2)

    n_elem = sum(len(p["elements"]) for p in pages) - 1
    result = {"workbookId": None, "pages": len(pages), "elements": n_elem,
              "kpis": sum(1 for e in emap if e["kind"] == "kpi-chart"),
              "warnings": warnings, "layoutFile": a.layout_out, "elementMap": a.element_map}
    if a.dry_run:
        print(f"DRY RUN: spec -> {a.spec_out} ({len(pages)} pages, {n_elem} elements)", file=sys.stderr)
    else:
        res = api_post("/v2/workbooks/spec", spec)
        try:
            wb = json.loads(res).get("workbookId")
        except json.JSONDecodeError:
            m = re.search(r"workbookId:\s*(\S+)", res)
            wb = m.group(1) if m else None
        if not wb: sys.exit(f"FATAL: workbook POST returned no id: {res[:300]}")
        result["workbookId"] = wb
    for w in warnings: print("   WARN:", w, file=sys.stderr)
    json.dump(result, open(a.out, "w"), indent=2)
    print(json.dumps(result))

if __name__ == "__main__":
    main()
