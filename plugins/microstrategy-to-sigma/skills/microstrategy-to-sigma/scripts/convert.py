#!/usr/bin/env python3
"""
convert.py — MicroStrategy bundle.json -> Sigma data-model spec + workbook spec.

Everything is derived programmatically from the bundle:
  - Sources: every logical table in bundle["tables"], path [<database>, <namespace>, <tableName>].
  - Base/fact table: the logical table that carries fact expressions.
  - Joins: attributes whose ID (key) form has expressions mapped to BOTH the fact
    table and a different lookup table that is present in the bundle. The fact-side
    expression and the lookup-side expression become the left/right join keys.
  - Metrics: parsed from bundle["metrics"] expression tokens (function + fact /
    metric object references + Distinct=True parameter -> CountDistinct).
  - Workbook pages: one page per dossier chapter; each chapter's dataset report's
    dataTemplate units give the grouping attributes + metric columns.

Usage:
  python3 convert.py --connection-id <uuid> --database CSA --folder-id <uuid> \
      [--inode-map inodes.json] [--bundle bundle.json] \
      [--dm-name "..."] [--wb-name "..."] \
      [--data-model-id <uuid>] [--orders-element-id <id>]

Outputs sigma_dm_spec.json and sigma_workbook_spec.json. The workbook spec uses
placeholders {{DATA_MODEL_ID}} / {{ORDERS_ELEMENT_ID}} unless the corresponding
args are given.
"""
import argparse
import json
import re


def friendly(col: str) -> str:
    """Sigma friendly-name normalization for ALL_CAPS_UNDERSCORE warehouse names."""
    return " ".join(p.capitalize() for p in col.split("_"))


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


# ---------------------------------------------------------------- bundle model
class Bundle:
    def __init__(self, raw):
        self.raw = raw
        self.tables = raw["tables"]          # logical table id -> def
        self.attributes = raw["attributes"]  # attribute id -> def
        self.metrics = raw["metrics"]        # metric id -> def
        self.facts = raw["facts"]            # fact id -> def
        self.reports = raw["reports"]
        self.dossier = raw["dossier"]

        # logical table id -> (name, schema/namespace, physical table name)
        self.table_info = {}
        for tid, t in self.tables.items():
            pt = t["physicalTable"]
            self.table_info[tid] = {
                "name": t["information"]["name"],
                "tableName": pt["tableName"],
                "namespace": pt.get("namespace"),
            }

        # fact table = the logical table that carries fact expressions
        fact_tids = set()
        for f in self.facts.values():
            for de in f["expressions"]:
                for tb in de.get("tables", []):
                    fact_tids.add(tb["objectId"])
        if len(fact_tids) != 1:
            raise SystemExit(f"expected exactly 1 fact table, found {fact_tids}")
        self.fact_tid = next(iter(fact_tids))

        # per logical table: attribute id -> list of forms
        #   form := {category, expr(column), isKeyForm}
        self.table_attr_forms = {}   # tid -> {attr_id: [form,...]}
        for tid, t in self.tables.items():
            am = {}
            for a in t.get("attributes", []):
                aid = a["information"]["objectId"]
                forms = []
                for f in a.get("forms", []):
                    forms.append({
                        "category": f["formCategory"]["name"],
                        "expr": f["expression"]["text"],
                        "isKeyForm": f.get("isKeyForm", False),
                        "lookupTable": f["lookupTable"]["objectId"],
                    })
                am[aid] = forms
            self.table_attr_forms[tid] = am

        # fact id -> physical column on the fact table
        self.fact_col = {}
        for fid, f in self.facts.items():
            for de in f["expressions"]:
                for tb in de.get("tables", []):
                    if tb["objectId"] == self.fact_tid:
                        self.fact_col[fid] = de["expression"]["text"]
        # name -> fact id (metric text sometimes references facts by bare name)
        self.fact_by_name = {f["information"]["name"]: fid
                             for fid, f in self.facts.items()}
        self.metric_by_name = {m["information"]["name"]: mid
                               for mid, m in self.metrics.items()}

    # ---- joins: attribute key form mapped to BOTH fact table and lookup table
    def derive_joins(self):
        joins = []
        fact_forms = self.table_attr_forms[self.fact_tid]
        for aid, forms in fact_forms.items():
            key_fact = next((f for f in forms if f["isKeyForm"]), None)
            if not key_fact:
                continue
            lookup_tid = key_fact["lookupTable"]
            if lookup_tid == self.fact_tid or lookup_tid not in self.tables:
                continue  # degenerate (fact-resident attr) or table not extracted
            lookup_forms = self.table_attr_forms.get(lookup_tid, {}).get(aid, [])
            key_lookup = next((f for f in lookup_forms if f["isKeyForm"]), None)
            if not key_lookup:
                continue
            joins.append({
                "attribute": aid,
                "lookup_tid": lookup_tid,
                "fact_col": key_fact["expr"],
                "lookup_col": key_lookup["expr"],
            })
        return joins

    # ---- columns each table contributes (any expression mapped to it)
    def table_columns(self, tid):
        cols = []
        seen = set()
        for aid, forms in self.table_attr_forms.get(tid, {}).items():
            for f in forms:
                c = f["expr"]
                if f["lookupTable"] == tid and c not in seen:
                    seen.add(c)
                    cols.append(c)
        if tid == self.fact_tid:
            for fid, c in self.fact_col.items():
                if c not in seen:
                    seen.add(c)
                    cols.append(c)
            # join keys on the fact side
            for j in self.derive_joins():
                if j["fact_col"] not in seen:
                    seen.add(j["fact_col"])
                    cols.append(j["fact_col"])
        return cols

    # ---- metric expression -> Sigma formula
    def metric_formula(self, mid, ref, expand_metrics=False):
        """ref(column_friendly) -> bracketed reference string.
        expand_metrics: inline referenced metrics (workbook context) instead of
        emitting [Metric Name] (data-model context)."""
        m = self.metrics[mid]
        toks = m["expression"]["tokens"]
        out = []
        i = 0
        while i < len(toks):
            t = toks[i]
            v, ty = t.get("value"), t.get("type")
            if ty == "function" and v not in ("=",):
                fname = v
                # peek a <...> parameter block for Distinct=True
                j = i + 1
                distinct = False
                if j < len(toks) and toks[j].get("value") == "<":
                    while j < len(toks) and toks[j].get("value") != ">":
                        if (toks[j].get("value") == "Distinct"
                                and j + 2 < len(toks)
                                and toks[j + 2].get("value") == "True"):
                            distinct = True
                        j += 1
                    i = j  # skip past the parameter block
                if fname == "Count" and distinct:
                    fname = "CountDistinct"
                out.append(fname)
            elif ty == "object_reference":
                tgt = t.get("target", {})
                sub = tgt.get("subType")
                oid = tgt.get("objectId")
                if sub == "fact":
                    out.append(ref(friendly(self.fact_col[oid])))
                elif sub == "metric":
                    if expand_metrics:
                        out.append("(" + self.metric_formula(
                            oid, ref, expand_metrics=True) + ")")
                    else:
                        out.append(f"[{self.metrics[oid]['information']['name']}]")
                else:
                    raise SystemExit(f"unhandled object_reference {sub} in metric "
                                     f"{m['information']['name']}")
            elif ty == "character":
                if v in ("<", ">"):
                    pass  # parameter block delimiters already handled
                elif v in ("(", ")", ",", "+", "-", "*", "/"):
                    out.append(v)
            elif ty == "identifier" or ty == "boolean":
                pass  # parameter names/values inside <...>
            i += 1
        # join with spaces around operators, none around parens
        f = ""
        for tok in out:
            if tok in ("+", "-", "*", "/"):
                f += f" {tok} "
            elif tok == ",":
                f += ", "
            else:
                f += tok
        return f

    # ---- metric expression -> warehouse SQL (for AE-emulation sql elements)
    def metric_sql(self, mid, fact_alias="ORDER_FACT"):
        m = self.metrics[mid]
        toks = m["expression"]["tokens"]
        FN = {"Sum": "SUM", "Count": "COUNT", "Avg": "AVG", "Max": "MAX",
              "Min": "MIN"}
        out = []
        distinct_pending = False
        i = 0
        while i < len(toks):
            t = toks[i]
            v, ty = t.get("value"), t.get("type")
            if ty == "function" and v not in ("=",):
                fname, distinct = v, False
                j = i + 1
                if j < len(toks) and toks[j].get("value") == "<":
                    while j < len(toks) and toks[j].get("value") != ">":
                        if (toks[j].get("value") == "Distinct"
                                and j + 2 < len(toks)
                                and toks[j + 2].get("value") == "True"):
                            distinct = True
                        j += 1
                    i = j
                out.append(FN.get(fname, fname.upper()))
                distinct_pending = distinct
            elif ty == "object_reference":
                tgt = t.get("target", {})
                if tgt.get("subType") == "fact":
                    out.append(f"{fact_alias}.{self.fact_col[tgt['objectId']]}")
                elif tgt.get("subType") == "metric":
                    out.append("(" + self.metric_sql(tgt["objectId"],
                                                     fact_alias) + ")")
            elif ty == "character":
                if v == "(":
                    out.append("(DISTINCT " if distinct_pending else "(")
                    distinct_pending = False
                elif v in (")", ",", "+", "-", "*", "/"):
                    out.append(v)
        # NB: '<'/'>' parameter blocks skipped above
            i += 1
        sql = ""
        for tok in out:
            if tok in ("+", "-", "*", "/"):
                sql += f" {tok} "
            elif tok == ",":
                sql += ", "
            else:
                sql += tok
        return sql

    # ---- clean per-(attribute keys) aggregation SQL for a report
    def report_attr_units(self, report):
        units = report["dataSource"]["dataTemplate"]["units"]
        return ([u for u in units if u.get("type") == "attribute"],
                [el for u in units if u.get("type") == "metrics"
                 for el in u["elements"]])

    def clean_group_aliases(self, report):
        attr_units, metric_units = self.report_attr_units(report)
        aliases = []
        for u in attr_units:
            key_col, desc_col = self.attribute_unit_cols(u["id"])
            aliases.append(friendly(key_col))
            if desc_col:
                aliases.append(friendly(desc_col))
        aliases += [el["name"] for el in metric_units]
        return aliases

    def build_clean_group_sql(self, database, report):
        """SELECT <attr keys>, MAX(<desc>) per desc form, <metric aggs>
        FROM fact JOIN needed dims GROUP BY keys — the same statement
        MicroStrategy generates for the report."""
        attr_units, metric_units = self.report_attr_units(report)
        fact = self.table_info[self.fact_tid]
        fq = lambda tid: ".".join([database,
                                   self.table_info[tid]["namespace"],
                                   self.table_info[tid]["tableName"]])
        joins_by_tid = {j["lookup_tid"]: j for j in self.derive_joins()}

        select, group_pos, needed_tids = [], [], []
        pos = 0
        for u in attr_units:
            key_col, desc_col = self.attribute_unit_cols(u["id"])
            a = self.attributes[u["id"]]
            lookup_tid = a["attributeLookupTable"]["objectId"]
            alias = self.table_info[lookup_tid]["tableName"]
            if lookup_tid != self.fact_tid and lookup_tid not in needed_tids:
                needed_tids.append(lookup_tid)
            pos += 1
            select.append(f'{alias}.{key_col} AS "{friendly(key_col)}"')
            group_pos.append(str(pos))
            if desc_col:
                pos += 1
                select.append(f'MAX({alias}.{desc_col}) AS "{friendly(desc_col)}"')
        for el in metric_units:
            select.append(f'{self.metric_sql(el["id"], fact["tableName"])} '
                          f'AS "{el["name"]}"')

        from_sql = f'{fq(self.fact_tid)} {fact["tableName"]}'
        for tid in needed_tids:
            j = joins_by_tid[tid]
            dim = self.table_info[tid]["tableName"]
            from_sql += (f'\n  JOIN {fq(tid)} {dim} ON '
                         f'{fact["tableName"]}.{j["fact_col"]} = '
                         f'{dim}.{j["lookup_col"]}')
        return ("SELECT " + ",\n       ".join(select)
                + f"\nFROM {from_sql}\nGROUP BY " + ", ".join(group_pos))

    def build_ae_sql(self, database, report, ae_cfg):
        """AE-emulation: clean groups, then every parent-key row takes the
        pinned representative row's label + metric values for its quirk key."""
        attr_units, metric_units = self.report_attr_units(report)
        qkey_f = friendly(ae_cfg["quirkKeyCol"])
        qdesc_f = friendly(ae_cfg["quirkDescCol"])
        parent_f = [friendly(c) for c in ae_cfg["parentKeyCols"]]

        def lit(v):
            s = str(v)
            try:
                float(s)
                return s
            except ValueError:
                return "'" + s.replace("'", "''") + "'"

        conds = []
        for w in ae_cfg["winners"]:
            parts = [f'w."{qkey_f}" = {lit(w[qkey_f])}']
            parts += [f'w."{p}" = {lit(w[p])}' for p in parent_f]
            conds.append("(" + " AND ".join(parts) + ")")

        out_cols = [f'f."{p}" AS "{p}"' for p in parent_f]
        out_cols.append(f'w."{qkey_f}" AS "{qkey_f}"')
        out_cols.append(f'w."{qdesc_f}" AS "{qdesc_f}"')
        out_cols += [f'w."{el["name"]}" AS "{el["name"]}"'
                     for el in metric_units]
        return (
            "WITH F AS (\n" + self.build_clean_group_sql(database, report)
            + "\n)\nSELECT " + ",\n       ".join(out_cols)
            + f'\nFROM F f\nJOIN F w ON w."{qkey_f}" = f."{qkey_f}"\n  AND ('
            + "\n    OR ".join(conds) + ")")

    # ---- display format for a metric (MSTR bundle format blocks are empty,
    # so derive from semantics: count/quantity -> integer, ratio/pct -> percent,
    # money facts -> currency)
    def metric_display_format(self, mid):
        m = self.metrics[mid]
        name = m["information"]["name"]
        if re.search(r"pct|percent|margin|ratio|rate", name, re.I):
            return {"kind": "number", "formatString": ",.2%"}
        toks = m["expression"]["tokens"]
        funcs = [t["value"] for t in toks if t.get("type") == "function"
                 and t.get("value") not in ("=",)]
        fact_cols = [self.fact_col[t["target"]["objectId"]] for t in toks
                     if t.get("type") == "object_reference"
                     and t.get("target", {}).get("subType") == "fact"]
        if any(f.startswith("Count") for f in funcs):
            return {"kind": "number", "formatString": ",.0f"}
        if any(re.search(r"REVENUE|PROFIT|COST|AMOUNT|PRICE", c) for c in fact_cols):
            return {"kind": "number", "formatString": "$,.2f"}
        if any(re.search(r"QUANTITY|UNITS|COUNT", c) for c in fact_cols):
            return {"kind": "number", "formatString": ",.0f"}
        return None

    # ---- attribute key + display columns for a report unit
    def attribute_unit_cols(self, aid):
        """Returns (key_col, desc_col_or_None) physical column names.

        MicroStrategy grids group by the attribute's KEY (ID) form and render
        the DESC form. When the DESC form differs from the key, the rendered
        label per element resolves to the max DESC value over the joined fact
        rows — so the converter emits the key as the grouping column and the
        DESC as a Max() calculation."""
        a = self.attributes[aid]
        forms = a["forms"]
        key = next((f for f in forms if f.get("category") == "ID"), forms[0])
        desc = next((f for f in forms if f.get("category") == "DESC"), None)
        key_col = key["expressions"][0]["expression"]["text"]
        desc_col = desc["expressions"][0]["expression"]["text"] if desc else None
        return key_col, desc_col


# ------------------------------------------------------------------- emitters
def ae_element_name(report_name):
    return f"{report_name} (MSTR AE)"


def build_dm_spec(b: Bundle, args, inode_map, ae_winners=None):
    conn = args.connection_id
    elements = []
    el_id = {}    # tid -> element id
    el_name = {}  # tid -> element name (= logical table name)

    def col_id(tid, col):
        tail = inode_map.get(b.table_info[tid]["tableName"])
        if tail:
            return f"inode-{tail}/{col}"
        return f"{slug(b.table_info[tid]['name'])}-{slug(col)}"

    for tid, info in b.table_info.items():
        eid = f"el-{slug(info['name'])}"
        el_id[tid], el_name[tid] = eid, info["name"]
        cols = b.table_columns(tid)
        elements.append({
            "id": eid,
            "kind": "table",
            "name": info["name"],
            "source": {
                "kind": "warehouse-table",
                "connectionId": conn,
                "path": [args.database, info["namespace"], info["tableName"]],
            },
            "columns": [
                {
                    "id": col_id(tid, c),
                    "name": friendly(c),
                    "formula": f"[{info['tableName']}/{friendly(c)}]",
                }
                for c in cols
            ],
        })

    # ---- join element (the consumable "Orders" view)
    joins = b.derive_joins()
    join_legs = [
        {
            "left": {"kind": "table", "elementId": el_id[b.fact_tid]},
            "right": {"kind": "table", "elementId": el_id[j["lookup_tid"]]},
            "columns": [{
                "left": f"[{friendly(j['fact_col'])}]",
                "right": f"[{friendly(j['lookup_col'])}]",
            }],
            "joinType": "left-outer",
        }
        for j in joins
    ]

    join_cols = []
    seen_names = set()

    def add_join_col(src_tid, col):
        name = friendly(col)
        if name in seen_names:
            return
        seen_names.add(name)
        join_cols.append({
            "id": f"ord-{slug(col)}",
            "name": name,
            "formula": f"[{el_name[src_tid]}/{name}]",
        })

    join_key_lookup_cols = {(j["lookup_tid"], j["lookup_col"]) for j in joins}
    # fact columns first (skip nothing on the fact side)
    for c in b.table_columns(b.fact_tid):
        add_join_col(b.fact_tid, c)
    # dim columns, skipping each join's own key column on the lookup side
    for j in joins:
        for c in b.table_columns(j["lookup_tid"]):
            if (j["lookup_tid"], c) in join_key_lookup_cols:
                continue
            add_join_col(j["lookup_tid"], c)

    # ---- metrics on the join element
    def dm_ref(col_friendly):
        return f"[{col_friendly}]"

    metrics = []
    for mid, m in b.metrics.items():
        md = {
            "id": f"m-{slug(m['information']['name'])}",
            "name": m["information"]["name"],
            "formula": b.metric_formula(mid, dm_ref, expand_metrics=False),
        }
        fmt = b.metric_display_format(mid)
        if fmt:
            md["format"] = fmt
        metrics.append(md)

    elements.append({
        "id": "el-orders",
        "kind": "table",
        "name": args.join_element_name,
        "source": {
            "kind": "join",
            "joins": join_legs,
            "primarySource": {"kind": "table", "elementId": el_id[b.fact_tid]},
        },
        "columns": join_cols,
        "metrics": metrics,
    })

    # ---- AE-emulation sql elements (MicroStrategy non-unique-key collapse)
    report_by_name = {r["information"]["name"]: r for r in b.reports.values()}
    for rname, cfg in (ae_winners or {}).items():
        report = report_by_name[rname]
        attr_units, metric_units = b.report_attr_units(report)
        aliases = ([friendly(c) for c in cfg["parentKeyCols"]]
                   + [friendly(cfg["quirkKeyCol"]), friendly(cfg["quirkDescCol"])]
                   + [el["name"] for el in metric_units])
        elements.append({
            "id": f"el-ae-{slug(rname)}",
            "kind": "table",
            "name": ae_element_name(rname),
            "source": {
                "kind": "sql",
                "connectionId": args.connection_id,
                "statement": b.build_ae_sql(args.database, report, cfg),
            },
            "columns": [
                {"id": f"ae-{slug(rname)}-{slug(a)}", "name": a,
                 "formula": f"[Custom SQL/{a}]"}
                for a in aliases
            ],
        })

    return {
        "name": args.dm_name,
        "folderId": args.folder_id,
        "schemaVersion": 1,
        "pages": [{"id": "page-1", "name": "Model", "elements": elements}],
    }


def build_ae_page(b: Bundle, args, ch_name, report, cfg, dm_id, el_ref,
                  report_keys):
    """Page backed by the AE-emulation sql element. Groups by parent keys +
    quirk key; label and metric values are already representative-resolved
    in the element's SQL, so metric columns aggregate the (single) row with
    Sum() and the label with Max()."""
    rname = report["information"]["name"]
    el_name = ae_element_name(rname)
    _attr_units, metric_units = b.report_attr_units(report)
    qkey_f = friendly(cfg["quirkKeyCol"])
    qdesc_f = friendly(cfg["quirkDescCol"])
    parent_f = [friendly(c) for c in cfg["parentKeyCols"]]

    columns, group_ids, calc_ids = [], [], []
    for p in parent_f:
        cid = f"c-{slug(ch_name)}-{slug(p)}"
        columns.append({"id": cid, "name": p, "formula": f"[{el_name}/{p}]"})
        group_ids.append(cid)
    kid = f"c-{slug(ch_name)}-{slug(qkey_f)}"
    columns.append({"id": kid, "name": qkey_f,
                    "formula": f"[{el_name}/{qkey_f}]"})
    group_ids.append(kid)
    did = f"c-{slug(ch_name)}-{slug(qdesc_f)}"
    columns.append({"id": did, "name": qdesc_f,
                    "formula": f"Max([{el_name}/{qdesc_f}])"})
    calc_ids.append(did)
    for el in metric_units:
        mname = el["name"]
        cid = f"c-{slug(ch_name)}-{slug(mname)}"
        col = {"id": cid, "name": mname,
               "formula": f"Sum([{el_name}/{mname}])"}
        fmt = b.metric_display_format(el["id"])
        if fmt:
            col["format"] = fmt
        columns.append(col)
        calc_ids.append(cid)

    report_keys[rname] = parent_f + [qdesc_f]
    return {
        "id": f"pg-{slug(ch_name)}",
        "name": ch_name,
        "elements": [{
            "id": f"tbl-{slug(ch_name)}",
            "kind": "table",
            "name": rname,
            "source": {"kind": "data-model", "dataModelId": dm_id,
                       "elementId": el_ref(el_name)},
            "columns": columns,
            "groupings": [{
                "id": f"g-{slug(ch_name)}",
                "groupBy": group_ids,
                "calculations": calc_ids,
            }],
        }],
    }


def build_workbook_spec(b: Bundle, args, ae_winners=None, dm_element_ids=None):
    dm_id = args.data_model_id or "{{DATA_MODEL_ID}}"
    dm_element_ids = dm_element_ids or {}
    join_name = args.join_element_name

    def el_ref(name):
        if name == join_name and args.orders_element_id:
            return args.orders_element_id
        return dm_element_ids.get(name, "{{ELEMENT_" + slug(name) + "}}")

    def wb_ref(col_friendly):
        return f"[{join_name}/{col_friendly}]"

    pages = []
    report_keys = {}  # report name -> ordered display column names of its keys
    # chapter -> dataset/report mapping comes from the dossier datasets by name
    report_by_name = {r["information"]["name"]: (rid, r)
                      for rid, r in b.reports.items()}
    for ch in b.dossier["chapters"]:
        ch_name = ch["name"]
        rid, report = report_by_name[ch_name]
        rname = report["information"]["name"]
        units = report["dataSource"]["dataTemplate"]["units"]

        if ae_winners and rname in ae_winners:
            pages.append(build_ae_page(b, args, ch_name, report,
                                       ae_winners[rname], dm_id, el_ref,
                                       report_keys))
            continue

        columns, group_ids, calc_ids, key_names = [], [], [], []
        filters = []
        for u in units:
            if u.get("type") == "attribute":
                key_col, desc_col = b.attribute_unit_cols(u["id"])
                cid = f"c-{slug(ch_name)}-{slug(key_col)}"
                columns.append({
                    "id": cid,
                    "name": friendly(key_col),
                    "formula": wb_ref(friendly(key_col)),
                })
                group_ids.append(cid)
                # MicroStrategy inner-joins the lookup table, so fact rows
                # with no matching dim row never appear in its grid. The DM
                # join is left-outer (other reports need all fact rows), so
                # drop the null group keys per-element to mirror MSTR.
                a = b.attributes[u["id"]]
                if a["attributeLookupTable"]["objectId"] != b.fact_tid:
                    filters.append({
                        "id": f"f-{slug(ch_name)}-{slug(key_col)}",
                        "columnId": cid,
                        "kind": "list",
                        "mode": "exclude",
                        "values": [None],
                    })
                if desc_col:
                    # DESC label rendered per key element = Max over fact rows
                    did = f"c-{slug(ch_name)}-{slug(desc_col)}"
                    columns.append({
                        "id": did,
                        "name": friendly(desc_col),
                        "formula": f"Max({wb_ref(friendly(desc_col))})",
                    })
                    calc_ids.append(did)
                    key_names.append(friendly(desc_col))
                else:
                    key_names.append(friendly(key_col))
            elif u.get("type") == "metrics":
                for el in u["elements"]:
                    mid = el["id"]
                    mname = b.metrics[mid]["information"]["name"]
                    cid = f"c-{slug(ch_name)}-{slug(mname)}"
                    col = {
                        "id": cid,
                        "name": mname,
                        "formula": b.metric_formula(mid, wb_ref,
                                                    expand_metrics=True),
                    }
                    fmt = b.metric_display_format(mid)
                    if fmt:
                        col["format"] = fmt
                    columns.append(col)
                    calc_ids.append(cid)

        report_keys[report["information"]["name"]] = key_names
        element = {
            "id": f"tbl-{slug(ch_name)}",
            "kind": "table",
            "name": report["information"]["name"],
            "source": {
                "kind": "data-model",
                "dataModelId": dm_id,
                "elementId": el_ref(join_name),
            },
            "columns": columns,
            "groupings": [{
                "id": f"g-{slug(ch_name)}",
                "groupBy": group_ids,
                "calculations": calc_ids,
            }],
        }
        if filters:
            element["filters"] = filters
        pages.append({
            "id": f"pg-{slug(ch_name)}",
            "name": ch_name,
            "elements": [element],
        })

    return {
        "name": args.wb_name,
        "folderId": args.folder_id,
        "schemaVersion": 1,
        "pages": pages,
    }, report_keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", default="bundle.json")
    ap.add_argument("--connection-id", required=True)
    ap.add_argument("--database", required=True,
                    help="warehouse database the Sigma connection reads")
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--inode-map", default=None,
                    help="JSON file: physical table name -> inode tail")
    ap.add_argument("--dm-name", default=None,
                    help="default: '<dossier name> (MSTR Model)'")
    ap.add_argument("--wb-name", default=None,
                    help="default: '<dossier name> (MSTR)'")
    ap.add_argument("--join-element-name", default="Orders")
    ap.add_argument("--data-model-id", default=None)
    ap.add_argument("--orders-element-id", default=None)
    ap.add_argument("--dm-element-ids", default=None,
                    help="JSON file: DM element name -> server element id")
    ap.add_argument("--ae-winners", default=None,
                    help="ae_winners.json from resolve_ae_winners.py")
    ap.add_argument("--out-dm", default="sigma_dm_spec.json")
    ap.add_argument("--out-wb", default="sigma_workbook_spec.json")
    args = ap.parse_args()

    b = Bundle(json.load(open(args.bundle)))
    dossier_name = b.dossier.get("name", "MicroStrategy")
    args.dm_name = args.dm_name or f"{dossier_name} (MSTR Model)"
    args.wb_name = args.wb_name or f"{dossier_name} (MSTR)"
    inode_map = json.load(open(args.inode_map)) if args.inode_map else {}
    ae_winners = json.load(open(args.ae_winners)) if args.ae_winners else None
    dm_element_ids = (json.load(open(args.dm_element_ids))
                      if args.dm_element_ids else None)

    dm = build_dm_spec(b, args, inode_map, ae_winners)
    wb, report_keys = build_workbook_spec(b, args, ae_winners, dm_element_ids)
    json.dump(dm, open(args.out_dm, "w"), indent=1)
    json.dump(wb, open(args.out_wb, "w"), indent=1)
    json.dump(report_keys, open("parity_keys.json", "w"), indent=1)

    print(f"fact table: {b.table_info[b.fact_tid]['name']}")
    for j in b.derive_joins():
        print(f"join: {b.table_info[b.fact_tid]['tableName']}.{j['fact_col']} = "
              f"{b.table_info[j['lookup_tid']]['tableName']}.{j['lookup_col']}")
    for el in dm["pages"][0]["elements"]:
        for m in el.get("metrics", []):
            print(f"metric: {m['name']} = {m['formula']}")
    print(f"wrote {args.out_dm}, {args.out_wb}")


if __name__ == "__main__":
    main()
