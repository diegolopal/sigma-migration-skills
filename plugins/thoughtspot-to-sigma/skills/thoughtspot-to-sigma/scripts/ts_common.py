#!/usr/bin/env python3
"""Shared logic for ThoughtSpot<->Sigma migration: a column RESOLVER derived from
the model TML, plus viz<->element mappers.

The migration reads a ThoughtSpot Liveboard's visualizations and rebuilds each as
a Sigma workbook element off a denormalized data-model element ("<root> View")
surfaced through a master table. Column display names differ between the tools:
ThoughtSpot keeps the worksheet/model column name (e.g. "Category"); the converted
Sigma denorm element suffixes joined-table columns with the relationship name
(e.g. "Category (PRODUCT_DIM)"). Rather than hardcode that mapping, `build_resolver`
derives it from the model TML itself, so it works for ANY model.
"""
import re, secrets, string

SIGMA_LOWERCASE_WORDS = {'a','an','the','and','but','or','for','nor','so','yet',
                         'at','by','in','of','on','to','up','as','into','via','per'}

def sigma_display_name(s):
    """Replicates the converter's sigmaDisplayName (SNAKE/camel -> Title Case,
    keeping small connector words lowercase)."""
    s = s or ""
    s = re.sub(r'([a-z])([A-Z])', r'\1_\2', s)
    s = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1_\2', s)
    words = [w for w in s.lower().split('_') if w]
    return ' '.join(w.capitalize() if (i == 0 or w not in SIGMA_LOWERCASE_WORDS) else w
                    for i, w in enumerate(words))

def nid(p="el"):
    return p + "-" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(8))

_CUR = {"USD": "$", "CAD": "$", "AUD": "$", "NZD": "$", "EUR": "€", "GBP": "£",
        "JPY": "¥", "CNY": "¥", "INR": "₹", "KRW": "₩", "BRL": "R$"}

def ts_format_to_sigma(pattern, currency_iso=None):
    """Map a ThoughtSpot column `format_pattern` (Java DecimalFormat, e.g. '#,##0.00',
    '0.0%') + optional `currency_type.iso_code` to a Sigma column format. The pattern
    never carries a currency symbol (that's currency_type) — so a '$' only appears
    when the source actually set a currency. Returns None if neither is set."""
    if not pattern and not currency_iso:
        return None
    pct = "%" in (pattern or "")
    core = (pattern or "").replace("%", "")
    decimals = len(core.split(".")[1]) if "." in core else (2 if currency_iso else 0)
    grp = "," if (not pattern or "," in core or currency_iso) else ""
    if currency_iso and not pct:
        sym = _CUR.get(currency_iso.upper(), currency_iso.upper() + " ")
        return {"kind": "number", "formatString": f"{sym}{grp}.{decimals}f", "currencySymbol": sym}
    return {"kind": "number", "formatString": f"{grp}.{decimals}{'%' if pct else 'f'}"}

def build_resolver(model_root):
    """model_root = the `model:`/`worksheet:` dict from a ThoughtSpot model TML.
    Returns { model_column_name: {"measure": bool, "ofv": <denorm display name>,
    "friendly": <paren-free alias>} }. The denorm element names joined-dim columns
    "<Field> (<TABLE>)" and fact columns "<Field>"; the root (fact) table is the
    one carrying the joins."""
    mts = model_root.get("model_tables") or model_root.get("tables") or []
    fact = None
    for t in mts:
        if t.get("joins"):
            fact = t["name"]; break
    if not fact and mts:
        fact = mts[0]["name"]
    resolver = {}
    for c in model_root.get("columns", model_root.get("worksheet_columns", [])):
        cid = c.get("column_id", "")
        props = c.get("properties") or {}
        ctype = (c.get("type") or props.get("column_type") or "").upper()
        iso = (props.get("currency_type") or {}).get("iso_code")
        fmt = ts_format_to_sigma(props.get("format_pattern"), iso)
        if "::" in cid:                       # physical column
            table, phys = cid.split("::", 1)
            field = sigma_display_name(phys)
            ofv = field if table == fact else f"{field} ({table})"
            name = c.get("name", field)
        elif c.get("formula_id"):             # formula column (lives on the fact element)
            name = c.get("name", c["formula_id"])
            ofv = name
        else:
            continue
        friendly = re.sub(r'\s+', ' ', name.replace("(", "").replace(")", "")).strip()
        resolver[name] = {"measure": ctype == "MEASURE", "ofv": ofv, "friendly": friendly, "fmt": fmt}
    return resolver

# ── ThoughtSpot side: a viz spec -> a Liveboard visualization dict (fixtures) ─
def ts_viz(idx, spec):
    dims, meas = spec.get("dims", []), spec["measures"]
    search = " ".join(f"[{c}]" for c in dims + meas)
    out_cols = list(dims) + [f"Total {m}" for m in meas]
    a = {"name": spec["name"], "tables": [{"id": "__MODEL_NAME__", "name": "__MODEL_NAME__",
            "fqn": "__MODEL_FQN__"}], "search_query": search,
         "answer_columns": [{"name": c} for c in out_cols],
         "table": {"table_columns": [{"column_id": c} for c in out_cols],
                   "ordered_column_ids": out_cols}}
    if spec["chart"] == "TABLE":
        a["display_mode"] = "TABLE_MODE"
    else:
        x = (dims or out_cols)[0]
        a["chart"] = {"type": spec["chart"], "chart_columns": [{"column_id": c} for c in out_cols],
                      "axis_configs": [{"x": [x], "y": [f"Total {m}" for m in meas]}]}
        a["display_mode"] = "CHART_MODE"
    return {"id": f"Viz_{idx}", "answer": a}

# ── Migration side: parse a Liveboard viz -> {name, chart, dims, measures} ────
def parse_ts_viz(v):
    a = v.get("answer")
    if not a:
        return None
    cols = [c["name"] for c in a.get("answer_columns", [])]
    measures = [c[len("Total "):] for c in cols if c.startswith("Total ")]
    dims = [c for c in cols if not c.startswith("Total ")]
    ctype = (a.get("chart") or {}).get("type", "TABLE")
    if a.get("display_mode") == "TABLE_MODE":
        ctype = "TABLE"
    return {"name": a.get("name", "Viz"), "chart": ctype, "dims": dims, "measures": measures,
            "filters": parse_filters(a.get("search_query", ""))}

def parse_filters(search_query):
    """Extract simple filter clauses from a ThoughtSpot search query:
    `[Col] = 'val'`, `[Col] != 'val'`, `[Col] = 'a' 'b'`. ThoughtSpot lowercases
    string literals in the query (case-insensitive match); we title-case single
    words as a best-effort for case-sensitive warehouses."""
    out = []
    for m in re.finditer(r"\[([^\]]+)\]\s*(=|!=)\s*((?:'[^']*'\s*)+)", search_query):
        col, op = m.group(1), m.group(2)
        vals = [v.title() if v.islower() else v for v in re.findall(r"'([^']*)'", m.group(3))]
        out.append({"col": col, "mode": "include" if op == "=" else "exclude", "values": vals})
    return out

_NUM = lambda fs: {"kind": "number", "formatString": fs}
KIND = {"KPI": "kpi-chart", "COLUMN": "bar-chart", "BAR": "bar-chart", "LINE": "line-chart",
        "STACKED_COLUMN": "bar-chart", "STACKED_BAR": "bar-chart",
        "AREA": "area-chart", "STACKED_AREA": "area-chart",
        "ADVANCED_COLUMN": "table", "TABLE": "table"}

def _region_type(name):
    # Infer a Sigma region-map regionType from the geo dimension's name. Sigma's
    # regionType enum (OpenAPI): country, us-state, us-county, us-zipcode, us-cbsa,
    # us-postal-place, ca-province. Default to us-postal-place (the most permissive
    # name-based bucket) for free city/place names.
    n = (name or "").lower()
    if re.search(r"country|nation", n):            return "country"
    if re.search(r"\bstate\b|province_state", n):  return "us-state"
    if re.search(r"county", n):                    return "us-county"
    if re.search(r"zip|postal_?code|postcode", n): return "us-zipcode"
    if re.search(r"cbsa|metro", n):                return "us-cbsa"
    if re.search(r"province", n):                  return "ca-province"
    return "us-postal-place"

def _fmt(entry):
    # Honor the column's actual ThoughtSpot format_pattern when present; otherwise
    # a neutral grouped number — do NOT invent a currency symbol the source lacked.
    return entry.get("fmt") or _NUM(",.0f")

def _resolve(resolver, base):
    return resolver.get(base) or {"measure": True, "ofv": base, "friendly": re.sub(r'[()]', '', base).strip()}

def sigma_element(spec, resolver, master="OFV"):
    """Build the element, then apply any ThoughtSpot search-query filters as
    Sigma element list-filters (adds the filter column if not already present)."""
    el = _element_core(spec, resolver, master)
    # Show value labels on bar/pie/donut (Sigma defaults them OFF). Lines stay clean.
    if el.get("kind") in ("bar-chart", "pie-chart", "donut-chart"):
        el["dataLabel"] = {"labels": "shown"}
    for f in spec.get("filters", []):
        e = _resolve(resolver, f["col"])
        existing = next((c for c in el["columns"] if c.get("name") == f["col"]), None)
        if existing:
            col_id = existing["id"]
        else:
            col_id = nid("f"); el["columns"].append({"id": col_id, "formula": f"[{master}/{e['friendly']}]", "name": f["col"]})
        el.setdefault("filters", []).append({"id": nid(), "columnId": col_id, "kind": "list",
                                             "mode": f["mode"], "values": f["values"]})
    return el

def _element_core(spec, resolver, master="OFV"):
    name, chart, dims, meas = spec["name"], spec["chart"], spec["dims"], spec["measures"]
    src = {"elementId": "m-ofv", "kind": "table"}
    mref = lambda b: f"Sum([{master}/{_resolve(resolver, b)['friendly']}])"
    dref = lambda b: f"[{master}/{_resolve(resolver, b)['friendly']}]"
    if chart == "KPI" or (not dims and meas):
        c = nid("c") + "-v"
        return {"id": nid(), "kind": "kpi-chart", "name": name, "source": src,
                "columns": [{"id": c, "formula": mref(meas[0]), "name": meas[0],
                             "format": _fmt(_resolve(resolver, meas[0]))}], "value": {"columnId": c}}
    if chart in ("PIE", "DONUT"):
        cid = nid("c"); vid = nid("v")
        cols = [{"id": cid, "formula": dref(dims[0]), "name": dims[0]},
                {"id": vid, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))}]
        # ThoughtSpot renders pies as donuts → use the donut-chart kind (the hole is
        # inherent to the kind; holeValue is only an optional center-label column ref).
        return {"id": nid(), "kind": "donut-chart", "name": name, "source": src, "columns": cols,
                "value": {"id": vid}, "color": {"id": cid}}
    if chart in ("PIVOT_TABLE", "PIVOT") and len(dims) >= 2:
        rid = nid("r"); cidd = nid("k")
        cols = [{"id": rid, "formula": dref(dims[0]), "name": dims[0]},
                {"id": cidd, "formula": dref(dims[1]), "name": dims[1]}]
        mids = []
        for m in meas:
            mid = nid("m"); cols.append({"id": mid, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))}); mids.append(mid)
        return {"id": nid(), "kind": "pivot-table", "name": name, "source": src, "columns": cols,
                "rowsBy": [{"id": rid}], "columnsBy": [{"id": cidd}], "values": mids}
    if chart in ("TABLE", "ADVANCED_COLUMN"):
        did = nid("d"); cols = [{"id": did, "formula": dref(dims[0]), "name": dims[0]}]; mids = []
        for m in meas:
            mid = nid("m"); cols.append({"id": mid, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))}); mids.append(mid)
        return {"id": nid(), "kind": "table", "name": name, "source": src, "columns": cols,
                "groupings": [{"id": nid(), "groupBy": [did], "calculations": mids}]}
    # Scatter / bubble — plot two measures (x vs y) with an optional category color.
    # Falls through to the default axis chart when there aren't two measures.
    if chart in ("SCATTER", "BUBBLE") and len(meas) >= 2:
        xc = nid("c"); yc = nid("c")
        cols = [{"id": xc, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))},
                {"id": yc, "formula": mref(meas[1]), "name": meas[1], "format": _fmt(_resolve(resolver, meas[1]))}]
        el = {"id": nid(), "kind": "scatter-chart", "name": name, "source": src, "columns": cols,
              "xAxis": {"columnId": xc}, "yAxis": {"columnIds": [yc]}}
        if dims:
            dc = nid("c"); cols.append({"id": dc, "formula": dref(dims[0]), "name": dims[0]})
            el["color"] = {"by": "category", "column": dc}
        return el
    # Combo (column + line) — first measure as bars, remaining measures as line series.
    if chart in ("LINE_COLUMN", "LINE_STACKED_COLUMN") and dims and len(meas) >= 2:
        xc = nid("c"); cols = [{"id": xc, "formula": dref(dims[0]), "name": dims[0]}]; ycids = []
        for i, m in enumerate(meas):
            y = nid("c"); cols.append({"id": y, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))})
            ycids.append(y if i == 0 else {"columnId": y, "type": "line"})
        return {"id": nid(), "kind": "combo-chart", "name": name, "source": src, "columns": cols,
                "xAxis": {"columnId": xc}, "yAxis": {"columnIds": ycids}}
    # Geographic region NAME (state/country/zip) -> region-map choropleth. Sigma
    # auto-colors from the measure column, so no separate color well is required.
    if chart in ("GEO_AREA", "GEO_BUBBLE") and dims and meas:
        gid = nid("c"); vid = nid("c")
        cols = [{"id": gid, "formula": dref(dims[0]), "name": dims[0]},
                {"id": vid, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))}]
        return {"id": nid(), "kind": "region-map", "name": name, "source": src, "columns": cols,
                "region": {"id": gid, "regionType": _region_type(dims[0])}}
    x = nid("x"); cols = [{"id": x, "formula": dref(dims[0]), "name": dims[0]}]; ymids = []
    for m in meas:
        y = nid("y"); cols.append({"id": y, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))}); ymids.append(y)
    return {"id": nid(), "kind": KIND.get(chart, "bar-chart"), "name": name, "source": src,
            "columns": cols, "xAxis": {"columnId": x}, "yAxis": {"columnIds": ymids}}

def master_element(specs, resolver, dm_id, denorm_elem, denorm_name="Order Fact View"):
    seen, cols, i = {}, [], 0
    for s in specs:
        for base in s.get("dims", []) + s["measures"] + [f["col"] for f in s.get("filters", [])]:
            e = _resolve(resolver, base)
            if e["friendly"] in seen:
                continue
            seen[e["friendly"]] = 1
            cols.append({"id": "ofv-%d" % i, "name": e["friendly"], "formula": f"[{denorm_name}/{e['ofv']}]"})
            i += 1
    return {"id": "m-ofv", "name": "OFV", "kind": "table",
            "source": {"dataModelId": dm_id, "elementId": denorm_elem, "kind": "data-model"},
            "columns": cols}
