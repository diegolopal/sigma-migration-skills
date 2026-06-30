#!/usr/bin/env python3
"""convert.py — GoodData workspace layout → Sigma data model spec.

Maps the LDM (datasets/attributes/facts/references) to a Sigma data model and
translates MAQL metrics to Sigma metric formulas (via maql.py). Datasets become
warehouse-table elements on the SAME warehouse GoodData reads, so parity runs
same-warehouse. Dimension datasets are emitted before fact datasets (Sigma
requires dim-before-fact ordering). Metrics that don't translate cleanly are
recorded in the flags file (flag, never fake).

Usage:
  python3 convert.py --workspace gd_workspace.json --connection-id <uuid> \
      --db CSA --schema TJ --out dm_spec.json --flags flags.json
"""
import argparse, json, re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from maql import translate


def sid(prefix, gid):
    return f"{prefix}_{re.sub(r'[^a-zA-Z0-9]', '_', gid)}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--connection-id", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--schema", required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--out", default="dm_spec.json")
    ap.add_argument("--flags", default="flags.json")
    a = ap.parse_args()

    layout = json.load(open(a.workspace))
    ldm = layout.get("ldm", {}) or {}
    an = layout.get("analytics", {}) or {}
    datasets = ldm.get("datasets", []) or []

    # symbol tables: GoodData object id -> Sigma display name (for MAQL translation)
    syms = {"fact": {}, "attribute": {}, "metric": {}}
    for d in datasets:
        for at in d.get("attributes", []):
            syms["attribute"][at["id"]] = at.get("title") or at["id"]
        for f in d.get("facts", []):
            syms["fact"][f["id"]] = f.get("title") or f["id"]
    for m in an.get("metrics", []):
        syms["metric"][m["id"]] = m.get("title") or m["id"]

    dataset_ids = {d["id"] for d in datasets}
    # dim-before-fact: datasets that are referenced (targets) first
    referenced = {r["identifier"]["id"] for d in datasets for r in d.get("references", [])} & dataset_ids
    ordered = [d for d in datasets if d["id"] in referenced] + \
              [d for d in datasets if d["id"] not in referenced]

    elements, flags = [], []
    el_id = {d["id"]: sid("el", d["id"]) for d in datasets}
    # per-dataset column id maps (for relationship keys + FK columns)
    col_by_srccol = {d["id"]: {} for d in datasets}

    # A SQL-backed dataset (dataSourceTableId null) is mapped to a warehouse-table on
    # its FROM table — Sigma's spec API can't resolve columns on a kind:"sql" source
    # (it would have to RUN the query to discover output columns), so a direct
    # warehouse-table is the reliable target. SQL-derived alias columns (a synthetic
    # grain key) are translated to Sigma formulas; passthrough columns map straight
    # through. Anything that won't translate is flagged (never faked).
    def from_path(d):
        m = re.search(r"\bFROM\s+([\w.\"]+)", (d.get("sql") or {}).get("statement", ""), re.I)
        parts = [p.strip('"') for p in m.group(1).split(".")] if m else []
        if len(parts) == 3: return parts
        if len(parts) == 2: return [a.db] + parts
        if len(parts) == 1: return [a.db, a.schema] + parts
        return [a.db, a.schema, d["id"].upper()]

    def table_of(d):
        return d["dataSourceTableId"]["id"] if d.get("dataSourceTableId") else from_path(d)[-1]

    def source_of(d, table):
        if d.get("sql"):
            return {"kind": "warehouse-table", "connectionId": a.connection_id, "path": from_path(d)}
        return {"kind": "warehouse-table", "connectionId": a.connection_id, "path": [a.db, a.schema, table]}

    # translate a SQL scalar expression to a Sigma formula (concatenation + CAST is
    # the common GoodData synthetic-key case); returns None if it can't be confident.
    _SQLKW = {"AND", "OR", "NOT", "AS", "CASE", "WHEN", "THEN", "ELSE", "END", "NULL", "DISTINCT"}
    def sql_expr_to_formula(expr, table):
        def cast_repl(m):
            inner, typ = m.group(1).strip(), m.group(2).upper()
            return f"Text({inner})" if any(t in typ for t in ("CHAR", "TEXT", "STRING")) else inner
        e = re.sub(r"CAST\s*\(\s*(.+?)\s+AS\s+(\w+)\s*\)", cast_repl, expr, flags=re.I)
        e = e.replace("||", "&")
        out = []
        for i, seg in enumerate(re.split(r"('[^']*')", e)):   # odd segments are quoted literals — leave them
            if i % 2 == 1:
                out.append(seg); continue
            def pref(m):
                w = m.group(1)
                return w if (w.upper() in _SQLKW or w == "Text") else f"[{table}/{w}]"
            out.append(re.sub(r"(?<![\w\[/])([A-Za-z_]\w*)(?!\s*\()(?![\w\]])", pref, seg))
        e2 = "".join(out)
        if re.search(r"(?<![\w])(?!Text\b)[A-Za-z_]\w*\s*\(", e2):   # an unhandled function call remains
            return None
        return e2

    # output-column -> Sigma formula map for a SQL dataset's SELECT list
    def sel_map_of(d, table):
        if not d.get("sql"):
            return {}
        m = re.search(r"\bSELECT\b(.*?)\bFROM\b", d["sql"]["statement"], flags=re.I | re.S)
        if not m:
            return {}
        items, depth, cur = [], 0, ""
        for ch in m.group(1):
            if ch == "(": depth += 1
            elif ch == ")": depth -= 1
            if ch == "," and depth == 0:
                items.append(cur); cur = ""
            else:
                cur += ch
        if cur.strip(): items.append(cur)
        out = {}
        for it in (x.strip() for x in items):
            am = re.search(r"\s+AS\s+(\w+)\s*$", it, re.I)
            if am:
                alias, expr = am.group(1), it[:am.start()].strip()
                out[alias] = (f"[{table}/{expr.split('.')[-1].strip(chr(34))}]"
                              if re.fullmatch(r"[\w.\"]+", expr) else sql_expr_to_formula(expr, table))
            else:
                col = it.split(".")[-1].strip('"')
                if col != "*":
                    out[col] = f"[{table}/{col}]"
        return out

    # FK columns on the source side, across both GoodData reference shapes.
    def ref_fk_cols(r):
        return [s["column"] for s in r["sources"]] if r.get("sources") else list(r.get("sourceColumns", []))

    for d in ordered:
        table = table_of(d)
        sel = sel_map_of(d, table)
        cols = []
        def add_col(cid, name, srccol):
            # passthrough by default; for SQL datasets honor the SELECT-list mapping
            formula = sel.get(srccol, f"[{table}/{srccol}]") if d.get("sql") else f"[{table}/{srccol}]"
            if formula is None:
                flags.append({"column": srccol, "dataset": d["id"],
                              "reason": f"SQL-derived column not translatable: {srccol}"}); return
            cols.append({"id": cid, "name": name, "formula": formula})
            col_by_srccol[d["id"]][srccol] = cid
        for at in d.get("attributes", []):
            add_col(sid("c", at["id"]), at.get("title") or at["id"], at["sourceColumn"])
        for f in d.get("facts", []):
            add_col(sid("c", f["id"]), f.get("title") or f["id"], f["sourceColumn"])
        # ensure FK columns referenced by relationships exist on the source side
        for r in d.get("references", []):
            for fk in ref_fk_cols(r):
                if fk not in col_by_srccol[d["id"]]:
                    add_col(sid("fk", fk), fk.replace("_", " ").title(), fk)

        elements.append({
            "id": el_id[d["id"]], "name": table, "kind": "table",
            "source": source_of(d, table),
            "columns": cols,
        })

    # relationships (on the fact/source element, pointing at the dim/target)
    for d in ordered:
        el = next(e for e in elements if e["id"] == el_id[d["id"]])
        rels = []
        for r in d.get("references", []):
            tgt = r["identifier"]["id"]
            # date-dimension links point at a dateInstance, not a dataset (either the
            # legacy sources[].target.type=="date" or a bare ref to a dateInstance id) —
            # skip; the date column stays a plain column available for grouping.
            if tgt not in dataset_ids:
                continue
            if any((s.get("target") or {}).get("type") == "date" for s in r.get("sources", [])):
                continue
            # join keys, across both reference shapes:
            #  legacy  -> sources:[{column, target:{id}}]  (target is an attribute id)
            #  current -> sourceColumns:["FK"]             (target is the ref'd dataset's grain)
            keys = []
            if r.get("sources"):
                for s in r["sources"]:
                    keys.append({"sourceColumnId": col_by_srccol[d["id"]][s["column"]],
                                 "targetColumnId": col_by_srccol[tgt][_attr_srccol(datasets, tgt, s["target"]["id"])]})
            elif r.get("sourceColumns"):
                grain = [g["id"] for g in next(x for x in datasets if x["id"] == tgt).get("grain", []) if g.get("type") == "attribute"]
                for i, fk in enumerate(r["sourceColumns"]):
                    tgt_attr = grain[i] if i < len(grain) else (grain[0] if grain else None)
                    if tgt_attr is None:
                        continue
                    keys.append({"sourceColumnId": col_by_srccol[d["id"]][fk],
                                 "targetColumnId": col_by_srccol[tgt][_attr_srccol(datasets, tgt, tgt_attr)]})
            if not keys:
                continue
            tgt_table = table_of(next(x for x in datasets if x["id"] == tgt))
            rels.append({"id": sid("rel", f"{d['id']}_{tgt}"), "name": tgt_table,
                         "targetElementId": el_id[tgt], "keys": keys})
        if rels:
            el["relationships"] = rels

    # metrics -> attach to the fact element (the last/non-referenced one)
    fact_el = next(e for e in elements if e["id"] == el_id[ordered[-1]["id"]])
    metrics = []
    for m in an.get("metrics", []):
        res = translate((m.get("content") or {}).get("maql", ""), syms)
        if res["ok"]:
            metrics.append({"id": sid("m", m["id"]), "name": m.get("title") or m["id"], "formula": res["formula"]})
        else:
            flags.append({"metric": m["id"], "title": m.get("title"), "category": res.get("category"),
                          "maql": (m.get("content") or {}).get("maql"), "reason": res["reason"]})
    if metrics:
        fact_el["metrics"] = metrics

    spec = {"name": layout.get("name") or "GoodData Migration", "schemaVersion": 1,
            "folderId": a.folder_id,
            "pages": [{"id": "p1", "name": "Model", "elements": elements}]}
    json.dump(spec, open(a.out, "w"), indent=2)
    json.dump(flags, open(a.flags, "w"), indent=2)
    print(f"DM spec -> {a.out}: {len(elements)} elements, "
          f"{sum(len(e.get('columns', [])) for e in elements)} cols, {len(metrics)} metrics translated")
    print(f"flags -> {a.flags}: {len(flags)} metric(s) flagged")
    for fl in flags:
        print(f"   FLAG {fl['metric']}: {fl['reason']}")


def _attr_srccol(datasets, ds_id, attr_id):
    d = next(x for x in datasets if x["id"] == ds_id)
    at = next(a for a in d.get("attributes", []) if a["id"] == attr_id)
    return at["sourceColumn"]


if __name__ == "__main__":
    main()
