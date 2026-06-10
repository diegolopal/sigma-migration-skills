#!/usr/bin/env python3
"""Dashboard contract -> Sigma workbook spec (LOCAL generation; does not POST).

Consumes the normalized contract from parse_lookml_dashboard.py plus the
explore's view .lkml files (to classify each view.field as a measure or a
dimension and derive its Sigma formula). Emits a /v2/workbooks/spec body:
  - a hidden "Data" page with a master table sourced from a data-model element
  - a dashboard page with one element per Looker tile (kpi/bar/area/line/donut/table)
  - controls from dashboard filters
  - a newspaper -> 24-col grid layout XML string

The data-model id / element id / connection id are pluggable (defaults are
placeholders so the spec generates locally); wire them to a real converted DM
before POSTing. Tile->kind, filter->control, and layout maps follow
refs/dashboard-contract.md and research/looker-dashboard-layout.md.
"""
import argparse, json, os, re, secrets, string, glob

def sid(p="el"): return p + "-" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(8))
def disp(seg):  return " ".join(w.capitalize() for w in str(seg).split("_"))
def leaf(field): return field.split(".")[-1]            # users.traffic_source -> traffic_source

TILE_KIND = {
    "single_value": "kpi-chart", "looker_column": "bar-chart", "looker_bar": "bar-chart",
    "looker_area": "area-chart", "looker_line": "line-chart", "looker_pie": "pie-chart",
    "looker_donut_multiples": "donut-chart", "table": "table", "looker_grid": "table",
    "looker_scatter": "scatter-chart",
}
AGG = {"average": "Avg", "sum": "Sum", "min": "Min", "max": "Max", "median": "Median"}

# ── LookML value_format_name / value_format -> Sigma column format ──────────
# Sigma columns carry an optional `format` object — for numbers:
#   {"kind": "number", "formatString": "<d3-format>"}  (see sigma-workbooks
#   reference/specification/formatting.md). LookML measures declare their display
#   via a named format (`value_format_name`) or a custom Excel-style mask
#   (`value_format`). Map the common named formats to d3 format strings; fall
#   back to a best-effort translation of a custom mask.
VALUE_FORMAT_NAME_MAP = {
    "usd":          "$,.2f",
    "usd_0":        "$,.0f",
    "gbp":          "£,.2f",
    "gbp_0":        "£,.0f",
    "eur":          "€,.2f",
    "eur_0":        "€,.0f",
    "percent_0":    ",.0%",
    "percent_1":    ",.1%",
    "percent_2":    ",.2%",
    "percent_3":    ",.3%",
    "percent_4":    ",.4%",
    "decimal_0":    ",.0f",
    "decimal_1":    ",.1f",
    "decimal_2":    ",.2f",
    "decimal_3":    ",.3f",
    "decimal_4":    ",.4f",
    "id":           "d",            # plain integer, no thousands separator
}

def custom_value_format_to_d3(mask):
    """Best-effort translate a LookML custom value_format (Excel-style mask) to a
    d3 format string. Handles the common shapes: currency prefix, thousands
    separator, fixed decimals, and percent. Returns None if nothing recognizable."""
    if not mask: return None
    m = mask.strip().strip('"')
    is_pct = m.endswith("%")
    sym = ""
    if m[:1] in "$£€¥": sym = m[0]
    has_thousands = "," in m
    dec = 0
    dm = re.search(r"\.(0+|#+)", m)        # ".00" or ".##" -> 2 decimals
    if dm: dec = len(dm.group(1))
    thou = "," if has_thousands else ""
    if is_pct:
        return f"{thou}.{dec}%"
    if sym or has_thousands or dec:
        return f"{sym}{thou}.{dec}f"
    return None

def sigma_format_for(value_format_name, value_format):
    """Resolve a LookML measure's format -> a Sigma column `format` object (or None)."""
    fs = None
    if value_format_name:
        fs = VALUE_FORMAT_NAME_MAP.get(value_format_name.strip().lower())
    if fs is None and value_format:
        fs = custom_value_format_to_d3(value_format)
    if not fs: return None
    return {"kind": "number", "formatString": fs}


# ── parse view files: classify fields as measure (agg + base col) or dimension ──
def build_field_index(view_files):
    measures = {}   # "view.field" -> (agg_type, base_display_or_None, sql)
    formats = {}    # "view.field" -> Sigma format dict (or None)
    dims = set()    # "view.field"
    view_pk = {}    # "view" -> primary-key dimension name
    for path in view_files:
        txt = open(path).read()
        txt = re.sub(r"#[^\n]*", "", txt)               # strip comments
        vm = re.search(r"view:\s*(\w+)", txt)
        if not vm: continue
        view = vm.group(1)
        for d in re.finditer(r"\b(dimension|dimension_group)\s*:\s*(\w+)", txt):
            dims.add(f"{view}.{d.group(2)}")
        # primary key: dimension block containing primary_key: yes
        for m in re.finditer(r"dimension:\s*(\w+)\s*\{", txt):
            name = m.group(1); start = m.end(); depth, i = 1, start
            while i < len(txt) and depth:
                depth += {"{": 1, "}": -1}.get(txt[i], 0); i += 1
            if re.search(r"primary_key:\s*yes", txt[start:i]):
                view_pk[view] = name
        # measure blocks: measure: name { ... }
        for m in re.finditer(r"measure:\s*(\w+)\s*\{", txt):
            name = m.group(1); start = m.end()
            depth, i = 1, start
            while i < len(txt) and depth:
                depth += {"{": 1, "}": -1}.get(txt[i], 0); i += 1
            block = txt[start:i]
            mtype = (re.search(r"type:\s*(\w+)", block) or [None, "count"])[1].lower()
            sqlm = re.search(r"sql:\s*(.+?);;", block, re.S)
            base = None
            if sqlm:
                s = sqlm.group(1)
                ref = re.search(r"\$\{(?:TABLE\}\.)?(\w+)\}?", s)  # ${dim} or ${TABLE}.col
                r2 = re.search(r"\$\{TABLE\}\.(\w+)", s)
                base = disp((r2 or ref).group(1)) if (r2 or ref) else None
            key = f"{view}.{name}"
            measures[key] = (mtype, base, (sqlm.group(1).strip() if sqlm else ""))
            # capture the measure's display format (named or custom mask)
            vfn = re.search(r"value_format_name:\s*(\w+)", block)
            vf = re.search(r'value_format:\s*"([^"]*)"', block)
            fmt = sigma_format_for(vfn.group(1) if vfn else None, vf.group(1) if vf else None)
            if fmt: formats[key] = fmt
    return measures, dims, view_pk, formats

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("contract")
    ap.add_argument("--views", required=True, help="dir of *.view.lkml for the explore")
    ap.add_argument("--dm-id", default="<DATA_MODEL_ID>")
    ap.add_argument("--element-id", default="<DENORM_ELEMENT_ID>")
    ap.add_argument("--dm-element-name", default="<DM_ELEMENT_NAME>",
                    help="display name of the data-model element the master pulls from")
    ap.add_argument("--master-name", default="Data")
    ap.add_argument("--folder-id", default="<FOLDER_ID>")
    ap.add_argument("--out", default="/tmp/workbook.spec.json")
    a = ap.parse_args()

    dash = json.load(open(a.contract))
    measures, dims, view_pk, formats = build_field_index(sorted(glob.glob(os.path.join(a.views, "*.view.lkml"))))
    warnings = []

    def fmt_for(f):
        """Sigma column `format` dict for a measure field (or None). Ratio
        measures inherit their own value_format if declared; else best-effort
        percent for ratio-typed measures left unset."""
        return formats.get(f)
    def apply_fmt(col, f):
        """Attach a Sigma number format to a tile column if the LookML measure
        declared one. Mutates+returns col for chaining."""
        ff = fmt_for(f)
        if ff: col["format"] = ff
        return col

    def is_measure(f): return f in measures
    def is_ratio(f):
        """Measure whose sql references other measures or is a type:number arithmetic
        expression (e.g. AOV = revenue/orders) — has no single base column."""
        if not is_measure(f): return False
        mtype, _base, sql = measures[f]
        view = f.split(".")[0]
        refs = [r for r in re.findall(r"\$\{(\w+)\}", sql or "") if f"{view}.{r}" in measures]
        body = re.sub(r"\$\{[^}]+\}", "X", sql or "")
        return bool(refs) or (mtype == "number" and bool(re.search(r"[+\-*/]", body)))
    def ratio_components(f):
        view = f.split(".")[0]
        return [f"{view}.{r}" for r in re.findall(r"\$\{(\w+)\}", measures[f][2])
                if f"{view}.{r}" in measures]
    def col_display(f, explore):
        """Display name of the MASTER column a field maps to. Joined-view columns
        in the denormalized DM element are disambiguated as '<Field> (<joinAlias>)'
        (the field's view prefix); base-explore-view columns are plain."""
        view = f.split(".")[0]
        suf = "" if view == explore else f" ({view})"
        if is_measure(f):
            if is_ratio(f): return None           # composite — components needed separately
            base = measures[f][1]                 # base column (None for plain count)
            return (base + suf) if base else None
        return disp(leaf(f)) + suf
    def pk_display(view, explore):
        """Display name of a view's primary-key column in the denorm element."""
        pk = view_pk.get(view)
        if not pk: return None
        return disp(pk) + ("" if view == explore else f" ({view})")
    def ratio_formula(f, explore):
        """Substitute each ${measure} with its Sigma agg formula; NULLIF→NullIf."""
        view = f.split(".")[0]
        def sub(m):
            key = f"{view}.{m.group(1)}"
            return "(" + formula_for(key, explore) + ")" if key in measures else m.group(0)
        e = re.sub(r"\$\{(\w+)\}", sub, measures[f][2])
        return re.sub(r"\bNULLIF\s*\(", "NullIf(", e, flags=re.I).replace("${TABLE}.", "").strip()
    def formula_for(f, explore):
        if is_measure(f) and is_ratio(f):
            return ratio_formula(f, explore)
        cd = col_display(f, explore)
        if is_measure(f):
            mtype = measures[f][0]; view = f.split(".")[0]
            if mtype == "count":
                # plain count on a JOINED view counts that view's entities, not fact
                # rows → CountDistinct on its PK in the denormalized element.
                if view != explore:
                    pkd = pk_display(view, explore)
                    if pkd: return f"CountDistinct([{a.master_name}/{pkd}])"
                return "Count()"
            if mtype == "count_distinct": return f"CountDistinct([{a.master_name}/{cd}])" if cd else "Count()"
            fn = AGG.get(mtype)
            return f"{fn}([{a.master_name}/{cd}])" if fn and cd else "Count()"
        return f"[{a.master_name}/{cd}]"
    def _warn_count(f, el):
        if measures.get(f, (None,))[0] == "count":
            v = f.split(".")[0]
            if v != el.get("explore") and not view_pk.get(v):
                warnings.append(f"tile '{el['name']}': '{f}' is a plain count on joined view '{v}' "
                                f"with no primary_key — used Count() (counts fact rows). Add a PK to "
                                f"'{v}' for CountDistinct parity.")

    # ── master columns: every dim col used + every measure base col + filter cols ──
    needed = {}   # display -> col id (stable, for control binding)
    def need(display):
        if display and display not in needed: needed[display] = sid("col")
        return needed.get(display)
    for el in dash["elements"]:
        if el.get("tileType") == "text":      # text tiles have no query/fields
            continue
        for f in el["fields"]:
            need(col_display(f, el["explore"]))
            # ratio measures: pull each referenced component measure's base column
            if is_measure(f) and is_ratio(f):
                for comp in ratio_components(f):
                    need(col_display(comp, el["explore"]))
            # plain count on a joined view needs that view's PK column in the master
            if is_measure(f) and measures[f][0] == "count" and f.split(".")[0] != el["explore"]:
                need(pk_display(f.split(".")[0], el["explore"]))
        for p in (el.get("pivots") or []):       # pivot/series fields are master columns too
            need(col_display(p, el["explore"]))
        for fld in (el.get("filters") or {}):        # tile-level hard-filter fields
            need(col_display(fld, el["explore"]))
    for flt in dash["filters"]:
        fld = flt.get("dimension") or flt.get("field")
        if fld: need(col_display(fld, flt.get("explore") or fld.split(".")[0]))
    # date_filter has no field; bind it to the column tiles listen it to
    for flt in dash["filters"]:
        if flt["type"] == "date_filter" and not flt.get("field"):
            for el in dash["elements"]:
                tgt = el["listen"].get(flt["name"])
                if tgt: flt["_resolvedField"] = tgt; flt["_resolvedExplore"] = el["explore"]; need(col_display(tgt, el["explore"])); break

    master = {
        "id": "m-master", "name": a.master_name, "kind": "table",
        "source": {"dataModelId": a.dm_id, "elementId": a.element_id, "kind": "data-model"},
        "columns": [{"id": cid, "formula": f"[{a.dm_element_name}/{d}]", "name": d} for d, cid in needed.items()],
    }

    # ── tile -> Sigma element ──
    # Looker newspaper rows are ~40px; Sigma grid rows are ~20px. Mapping them 1:1
    # halves every tile's height — and Sigma SUPPRESSES x-axis category labels (and
    # most y gridline labels) when the chart band is that short, so migrated bar
    # charts rendered with NO category names (same short-band suppression seen on
    # tableau, beads-sigma-tkkv). Scale rows 2x so tile heights land near their
    # Looker pixel heights and axis labels render.
    ROW_SCALE = 2
    elements, layout_items = [], []
    for el in dash["elements"]:
        # Text/markdown tiles → Sigma text element (kind: "text"). No query, no
        # master columns, no source — just a Markdown `body` (title_text as a
        # heading + body_text). See sigma-workbooks reference/specification/text.md.
        if el["tileType"] == "text":
            eid = sid()
            title = (el.get("titleText") or "").strip()
            bodytxt = (el.get("bodyText") or "").strip()
            parts = []
            # Looker often duplicates the title as a heading in body_text; only
            # prepend title_text as an H1 if body_text doesn't already lead with it.
            first_line = bodytxt.splitlines()[0].lstrip("# ").strip().lower() if bodytxt else ""
            if title and title.lower() != first_line:
                parts.append(f"# {title}")
            if bodytxt:
                parts.append(bodytxt)
            body = "\n\n".join(parts) if parts else (el.get("name") or title or "")
            elements.append({"id": eid, "kind": "text", "body": body})
            L = el["layout"]; c0 = L["col"] + 1; c1 = L["col"] + 1 + L["width"]
            r0 = L["row"] * ROW_SCALE + 1; r1 = r0 + L["height"] * ROW_SCALE
            layout_items.append((eid, c0, c1, r0, r1, "text"))
            continue
        kind = TILE_KIND.get(el["tileType"])
        if not kind:
            warnings.append(f"tile '{el['name']}' type '{el['tileType']}' has no Sigma mapping — skipped")
            continue
        ex = el["explore"]
        ms = [f for f in el["fields"] if is_measure(f)]
        ds = [f for f in el["fields"] if not is_measure(f)]
        eid = sid()
        base = {"id": eid, "kind": kind, "name": el["name"], "source": {"elementId": "m-master", "kind": "table"}}
        field2cid = {}   # "view.field" -> tile column id (for sorts: resolution)

        if kind == "kpi-chart":
            vf = formula_for(ms[0], ex) if ms else "Count()"
            cid = sid("v")
            col = {"id": cid, "formula": vf, "name": el["name"]}
            if ms: apply_fmt(col, ms[0])      # carry LookML value_format -> Sigma $/%/decimals
            base["columns"] = [col]
            base["value"] = {"columnId": cid}
            if ms: _warn_count(ms[0], el)
            if el.get("showComparison"):
                warnings.append(f"tile '{el['name']}': Looker show_comparison ({el.get('comparisonType')}) — "
                                f"Sigma KPI spec has no comparison/delta slot; add a second KPI side-by-side or set it in the UI")
        elif kind == "scatter-chart":
            # both axes are measures; the (optional) dimension becomes the color split
            xf = ms[0] if ms else None
            yf = ms[1] if len(ms) > 1 else None
            xid, yid, cols = sid("x"), sid("y"), []
            xcol = {"id": xid, "formula": formula_for(xf, ex) if xf else "Count()",
                    "name": disp(leaf(xf)) if xf else "X"}
            ycol = {"id": yid, "formula": formula_for(yf, ex) if yf else "Count()",
                    "name": disp(leaf(yf)) if yf else "Y"}
            if xf: apply_fmt(xcol, xf)
            if yf: apply_fmt(ycol, yf)
            cols.append(xcol); cols.append(ycol)
            base["columns"] = cols
            base["xAxis"] = {"columnId": xid}; base["yAxis"] = {"columnIds": [yid]}
            if ds:
                clr = sid("clr")
                cols.append({"id": clr, "formula": formula_for(ds[0], ex), "name": col_display(ds[0], ex)})
                base["color"] = {"by": "category", "column": clr}
            for mf in (ms[:2] or []): _warn_count(mf, el)
        elif kind in ("bar-chart", "area-chart", "line-chart"):
            cols, ymids = [], []
            xid = sid("x"); xf = ds[0] if ds else (el["fields"][0] if el["fields"] else None)
            cols.append({"id": xid, "formula": formula_for(xf, ex) if xf else "Count()",
                         "name": (col_display(xf, ex) if xf else None) or "Group"})
            if xf: field2cid[xf] = xid
            for mf in (ms or []):
                yid = sid("y")
                cols.append(apply_fmt({"id": yid, "formula": formula_for(mf, ex), "name": disp(leaf(mf))}, mf))
                ymids.append(yid)
                field2cid[mf] = yid
                _warn_count(mf, el)
            if not ymids:
                yid = sid("y"); cols.append({"id": yid, "formula": "Count()", "name": "Count"}); ymids.append(yid)
            base["columns"] = cols
            base["xAxis"] = {"columnId": xid}; base["yAxis"] = {"columnIds": ymids}
            # Looker pivot → Sigma series via the color channel (split/stack by the
            # pivot dimension). One color channel; extra pivots → UI.
            if el["pivots"]:
                pf = el["pivots"][0]
                pcid = sid("clr")
                cols.append({"id": pcid, "formula": formula_for(pf, ex), "name": col_display(pf, ex)})
                base["color"] = {"by": "category", "column": pcid}
                if len(el["pivots"]) > 1:
                    warnings.append(f"tile '{el['name']}': multiple pivots {el['pivots']} — only first set as series; add the rest in Sigma UI")
            if el["tileType"] == "looker_donut_multiples":
                warnings.append(f"tile '{el['name']}': donut_multiples -> single donut-chart (Looker shows N donuts)")
        elif kind in ("pie-chart", "donut-chart"):
            # donut/pie use value + color (slice category), NOT xAxis/yAxis.
            catf = el["pivots"][0] if el["pivots"] else (ds[0] if ds else (el["fields"][0] if el["fields"] else None))
            valf = ms[0] if ms else None
            catid = sid("cat"); valid = sid("val")
            valcol = {"id": valid, "formula": formula_for(valf, ex) if valf else "Count()",
                      "name": (disp(leaf(valf)) if valf else "Count")}
            if valf: apply_fmt(valcol, valf)
            base["columns"] = [
                {"id": catid, "formula": formula_for(catf, ex) if catf else "Count()",
                 "name": (col_display(catf, ex) if catf else None) or "Category"},
                valcol,
            ]
            base["value"] = {"id": valid}      # donut/pie use value.id (KPI uses value.columnId)
            base["color"] = {"id": catid}
            if catf: field2cid[catf] = catid
            if valf: field2cid[valf] = valid
            if valf: _warn_count(valf, el)
            if el["tileType"] == "looker_donut_multiples":
                warnings.append(f"tile '{el['name']}': donut_multiples → single donut sliced by "
                                f"'{leaf(catf) if catf else 'category'}'; the per-multiple dimension is dropped — review in Sigma")
        elif kind == "table":
            cols, gids, cids = [], [], []
            for f in el["fields"] + (el.get("pivots") or []):
                tcol = {"id": sid("c"), "formula": formula_for(f, ex), "name": disp(leaf(f))}
                if is_measure(f):
                    apply_fmt(tcol, f); _warn_count(f, el); cids.append(tcol["id"])
                else:
                    gids.append(tcol["id"])
                cols.append(tcol)
                field2cid[f] = tcol["id"]
            base["columns"] = cols
            # A Looker table tile is an AGGREGATING query (group by dims, aggregate
            # measures). Without `groupings` a Sigma table with dim + Sum(...) columns
            # renders one row per SOURCE row (no roll-up). Verified shape (hand-PATCH
            # round-trip): groupings:[{id, groupBy:[dim col ids], calculations:[measure
            # col ids]}].
            if gids and cids:
                base["groupings"] = [{"id": sid("g"), "groupBy": gids, "calculations": cids}]
            if el.get("pivots"):
                warnings.append(f"tile '{el['name']}': pivot {el['pivots']} flattened to columns — "
                                f"rebuild as a Sigma pivot-table for true cross-tab")

        # tile-level hard filters → element filters (string values; date/numeric → warn)
        for fld, val in (el.get("filters") or {}).items():
            d = col_display(fld, ex)
            if "date" in leaf(fld).lower() or isinstance(val, (int, float)):
                warnings.append(f"tile '{el['name']}': filter {fld}={val} (date/numeric) — add manually in Sigma")
                continue
            col = next((c for c in base["columns"] if c["name"] == d), None)
            if not col:
                # filter-only field: the tile filters by it but doesn't display it —
                # carry it hidden so the filter works without adding a visible column.
                col = {"id": sid("c"), "formula": f"[{a.master_name}/{d}]", "name": d, "hidden": True}
                base["columns"].append(col)
            vals = [v.strip() for v in str(val).split(",") if v.strip()]
            base.setdefault("filters", []).append(
                {"id": sid("f"), "columnId": col["id"], "kind": "list", "mode": "include", "values": vals})
        # tile sorts: -> Sigma sort. Verified shapes (live POST + readback + render,
        # 2026-06-10):
        #   bar/line/area/scatter : xAxis.sort  = {by: <colId>, direction}
        #   pie/donut             : color.sort  = {by: <colId>, direction}
        #   UNGROUPED table       : element sort = [{columnId, direction}]
        #   GROUPED table         : groupings[0].sort = [{columnId, direction}] —
        #     element-level sort on a grouped table 400s with "Sort column not found"
        #     for BOTH groupBy and calculation column ids; nesting the sort inside the
        #     grouping entry is the shape that posts, round-trips, and orders groups.
        for si, s in enumerate(el.get("sorts") or []):
            toks = str(s).split()
            sf = toks[0]
            direction = "descending" if (len(toks) > 1 and toks[1].lower().startswith("desc")) else "ascending"
            cid = field2cid.get(sf)
            if not cid:
                warnings.append(f"tile '{el['name']}': sort field '{sf}' not among the tile's columns — sort skipped")
                continue
            if kind in ("bar-chart", "area-chart", "line-chart", "scatter-chart"):
                if si == 0: base.setdefault("xAxis", {})["sort"] = {"by": cid, "direction": direction}
            elif kind in ("pie-chart", "donut-chart"):
                if si == 0: base.setdefault("color", {})["sort"] = {"by": cid, "direction": direction}
            elif kind == "table":
                if base.get("groupings"):
                    base["groupings"][0].setdefault("sort", []).append({"columnId": cid, "direction": direction})
                else:
                    base.setdefault("sort", []).append({"columnId": cid, "direction": direction})
        # Looker table calcs (dynamic_fields) → Sigma formula columns
        for dyn in (el.get("dynamicFields") or []):
            if not isinstance(dyn, dict):
                continue
            expr = dyn.get("expression") or ""
            label = dyn.get("label") or dyn.get("table_calculation") or "Calc"
            def _subfield(m):
                f = m.group(1)
                return formula_for(f, ex) if is_measure(f) else f"[{a.master_name}/{col_display(f, ex)}]"
            sig = re.sub(r"\$\{([\w.]+)\}", _subfield, expr)
            sig = re.sub(r"\brunning_total\s*\(", "CumulativeSum(", sig)
            sig = re.sub(r"\bsum\s*\(", "GrandTotal(", sig)          # pct-of-total denominator
            sig = re.sub(r"\bmean\s*\(", "GrandTotal(", sig)
            if re.search(r"\b(rank|row|offset|pivot_\w+|percentile)\s*\(", sig):
                warnings.append(f"tile '{el['name']}': table calc '{label}' uses an unsupported "
                                f"window fn — review: {expr}")
                continue
            base.setdefault("columns", []).append({"id": sid("tc"), "formula": sig.strip(), "name": label})
        elements.append(base)

        # newspaper -> 24-col grid (rows scaled — see ROW_SCALE above)
        L = el["layout"]; c0 = L["col"] + 1; c1 = L["col"] + 1 + L["width"]
        r0 = L["row"] * ROW_SCALE + 1; r1 = r0 + L["height"] * ROW_SCALE
        layout_items.append((eid, c0, c1, r0, r1, kind))

    # ── controls from dashboard filters ──
    controls = []
    for flt in dash["filters"]:
        fld = flt.get("dimension") or flt.get("field") or flt.get("_resolvedField")
        fex = flt.get("explore") or flt.get("_resolvedExplore") or (fld.split(".")[0] if fld else "")
        cdisp = col_display(fld, fex) if fld else None
        col_id = needed.get(cdisp)
        ctype = "date-range" if flt["type"] == "date_filter" else "list"
        ctrl = {"kind": "control", "id": sid("ctrl"), "controlId": flt["name"].lower().replace(" ", "-"),
                "name": flt["title"], "controlType": ctype}
        if col_id:
            ctrl["filters"] = [{"source": {"kind": "table", "elementId": "m-master"}, "columnId": col_id}]
            if ctype == "list":
                ctrl.update({"mode": "include", "selectionMode": "multiple", "values": [],
                             "source": {"kind": "source", "source": {"kind": "table", "elementId": "m-master"}, "columnId": col_id}})
            else:
                ctrl["mode"] = "between"
        else:
            warnings.append(f"filter '{flt['name']}': could not bind to a master column")
        controls.append(ctrl)

    # ── layout finalize: top control bar, tall titled KPIs, downshifted tiles ──
    # The raw newspaper→grid math (above) honors Looker's pixel positions, but two
    # Looker→Sigma quirks need fixing for a tidy, readable dashboard:
    #   1. Sigma kpi-chart HIDES its title (the element name / measure label) when
    #      the tile is shorter than ~5 grid rows / ~150px — Looker KPIs are usually
    #      2-3 rows tall, so every title vanishes (bare floating numbers). Fix: lay
    #      KPIs as a full-width strip of equal, TALL tiles (height >= 6).
    #      See memory feedback_sigma_kpi_label_height.md.
    #   2. Dashboard controls (filters) carry no layout, so they orphan at the
    #      bottom-left. Looker shows filters at the TOP. Fix: a control row at row 0
    #      and shift every tile DOWN by that row's height.
    GRID = 24
    CTRL_H = 3                 # control-bar height (grid rows)
    KPI_H = 6                  # KPI tile height — >= 5 so the title renders

    # (a) Top control bar: lay controls side-by-side across row 0, evenly. Each
    #     control needs a layout entry so it docks at the top instead of orphaning.
    ctrl_items = []
    if controls:
        n = len(controls)
        cw = max(1, GRID // n)
        x = 1
        for i, c in enumerate(controls):
            c1 = (x + cw) if i < n - 1 else (GRID + 1)   # last fills to the edge
            ctrl_items.append((c["id"], x, c1, 1, 1 + CTRL_H, "control"))
            x = c1
    ctrl_h = CTRL_H if controls else 0

    # (b) KPI strip: pull every KPI out of its Looker position and lay them as one
    #     full-width row of equal, TALL tiles directly under the control bar — this
    #     is the only reliable way to keep their titles visible.
    kpi_ids = [e for (e, *_rest, k) in layout_items if k == "kpi-chart"]
    other_items = [it for it in layout_items if it[5] != "kpi-chart"]
    new_items = list(ctrl_items)
    kpi_row0 = 1 + ctrl_h
    if kpi_ids:
        n = len(kpi_ids)
        kw = max(1, GRID // n)
        x = 1
        for i, e in enumerate(kpi_ids):
            c1 = (x + kw) if i < n - 1 else (GRID + 1)   # last fills to the edge
            new_items.append((e, x, c1, kpi_row0, kpi_row0 + KPI_H, "kpi-chart"))
            x = c1
    kpi_h = KPI_H if kpi_ids else 0

    # (c) Shift all remaining tiles DOWN below the control bar + KPI strip, by the
    #     amount their original top-row sat above the first non-KPI tile (so we
    #     close the gap the KPIs left and never overlap the bars). Preserve their
    #     relative vertical order and columns from the newspaper math.
    body_off = ctrl_h + kpi_h
    top = min((r0 for (_e, _c0, _c1, r0, _r1, _k) in other_items), default=1)
    for (e, c0, c1, r0, r1, k) in other_items:
        h = r1 - r0
        nr0 = (r0 - top) + 1 + body_off
        new_items.append((e, c0, c1, nr0, nr0 + h, k))
    layout_items = new_items

    # ── layout XML (single top-level field; 24-col grid) ──
    page_id = "page-dash"
    les = "\n".join(f'  <LayoutElement elementId="{e}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'
                    for (e, c0, c1, r0, r1, _k) in layout_items)
    layout_xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
                  f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">\n'
                  f'{les}\n</Page>')

    spec = {
        "name": f"{dash['title']} (from Looker)", "folderId": a.folder_id, "schemaVersion": 1,
        "layout": layout_xml,
        "pages": [
            {"id": "page-data", "name": "Data", "elements": [master]},
            {"id": page_id, "name": dash["title"], "elements": controls + elements},
        ],
    }
    open(a.out, "w").write(json.dumps(spec, indent=2))
    print(f"wrote {a.out}")
    print(f"  master cols: {len(master['columns'])}  tiles: {len(elements)}  controls: {len(controls)}")
    for e in elements:
        print(f"    {e['kind']:11} {e.get('name', '(text)')}")
    if warnings:
        print("\n  WARNINGS:")
        for w in warnings: print("   -", w)

if __name__ == "__main__":
    main()
