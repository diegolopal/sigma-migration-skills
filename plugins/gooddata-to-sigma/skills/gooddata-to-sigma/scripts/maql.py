#!/usr/bin/env python3
"""maql.py — MAQL → Sigma formula translator.

Scoped to the constructs the converter handles cleanly; everything else is
returned as UNHANDLED with the raw MAQL (flag, never fake). The hard MAQL
surface — BY / WITHIN / BY ALL context and FOR time transforms — is detected and
flagged here, to be measured by gap-scout, not silently mis-translated.

translate(maql, syms) -> {"ok": bool, "formula": str|None, "reason": str|None}
  syms = {"fact": {id: "Display Name"}, "attribute": {id:.}, "metric": {id:.}}
"""
import re

AGG = {"SUM": "Sum", "AVG": "Avg", "MIN": "Min", "MAX": "Max", "MEDIAN": "Median"}
# Hard MAQL surface, categorized so flags are actionable (not just "unsupported").
# These are workbook-level constructs, NOT data-model metrics — they route to the
# workbook builder, not the DM. category drives gap-scout / assessment reporting.
TIME_KW = ["FOR PREVIOUS", "FOR NEXT", "FOR "]      # -> Sigma DateLookback in a date-grouped element
CONTEXT_KW = ["BY ALL", "WITHIN", " BY "]            # -> Sigma grouping / Level-scoped aggregate


def _ref(syms, kind, gid):
    name = syms.get(kind, {}).get(gid)
    return f"[{name}]" if name else None


def translate(maql, syms):
    src = " ".join(maql.split())
    body = re.sub(r"^\s*SELECT\s+", "", src, flags=re.I).strip()

    up = body.upper()
    for kw in TIME_KW:
        if kw in up:
            return {"ok": False, "formula": None, "category": "TIME_INTEL",
                    "reason": f"time transform '{kw.strip()}' → Sigma DateLookback in a date-grouped workbook element (workbook-level, not a DM metric)"}
    for kw in CONTEXT_KW:
        if kw in up:
            return {"ok": False, "formula": None, "category": "CONTEXT",
                    "reason": f"context aggregation '{kw.strip()}' → Sigma workbook grouping / Level-scoped aggregate (workbook-level, not a DM metric)"}

    # WHERE filter -> conditional aggregate (SumIf/AvgIf/.../CountDistinctIf).
    # Split off the WHERE clause and translate the predicate; aggregates below
    # then emit their *If variants. MEDIAN+WHERE has no Sigma *If → unhandled.
    cond = None
    parts = re.split(r"\sWHERE\s", body, maxsplit=1, flags=re.I)
    if len(parts) == 2:
        body, where = parts[0].strip(), parts[1].strip()
        c = re.sub(r"\{label/([^.}]+)\.[^}]+\}", lambda m: _ref(syms, "attribute", m.group(1)) or m.group(0), where)
        c = re.sub(r"\{attribute/([^}]+)\}", lambda m: _ref(syms, "attribute", m.group(1)) or m.group(0), c)
        if re.search(r"\{[^}]+\}", c):
            return {"ok": False, "formula": None, "category": "UNHANDLED",
                    "reason": f"WHERE predicate has an unresolved reference: {where[:60]}"}
        cond = c.strip()
        if re.search(r"\bMEDIAN\b", body, re.I):
            return {"ok": False, "formula": None, "category": "UNHANDLED",
                    "reason": "MEDIAN with WHERE has no Sigma conditional-aggregate equivalent"}

    out = body
    # COUNT({attribute/x}) -> CountDistinct([Name]) (GoodData COUNT of an attribute = distinct)
    def count_attr(m):
        r = _ref(syms, "attribute", m.group(1))
        if not r: return m.group(0)
        return f"CountDistinctIf({r}, {cond})" if cond else f"CountDistinct({r})"
    out = re.sub(r"COUNT\(\s*\{attribute/([^}]+)\}\s*\)", count_attr, out, flags=re.I)

    # AGG({fact/x}) and AGG(<expr of facts>) -> Sigma agg (conditional when WHERE present)
    def agg_fact(m):
        fn = AGG[m.group(1).upper()]
        inner = m.group(2)
        return f"{fn}If({inner}, {cond})" if cond else f"{fn}({inner})"
    # first resolve fact refs to column names inside any expression
    def fact_ref(m):
        r = _ref(syms, "fact", m.group(1))
        return r if r else m.group(0)
    out = re.sub(r"\{fact/([^}]+)\}", fact_ref, out)
    out = re.sub(r"(SUM|AVG|MIN|MAX|MEDIAN)\(([^()]*)\)", agg_fact, out, flags=re.I)

    # metric refs -> reference other DM metrics by name
    def metric_ref(m):
        r = _ref(syms, "metric", m.group(1))
        return r if r else m.group(0)
    out = re.sub(r"\{metric/([^}]+)\}", metric_ref, out)

    # leftover unresolved object refs => unhandled
    leftover = re.search(r"\{(fact|attribute|metric|label)/([^}]+)\}", out)
    if leftover:
        return {"ok": False, "formula": None, "category": "UNHANDLED",
                "reason": f"unresolved MAQL reference {leftover.group(0)}"}

    return {"ok": True, "formula": out.strip(), "category": "AUTO", "reason": None}


if __name__ == "__main__":
    syms = {"fact": {"net_revenue": "Net Revenue", "net_profit": "Net Profit"},
            "attribute": {"order_id": "Order Id", "region": "Region"},
            "metric": {"m_net_revenue": "Net Revenue", "m_order_count": "Order Count"}}
    for q in ["SELECT SUM({fact/net_revenue})",
              "SELECT COUNT({attribute/order_id})",
              "SELECT {metric/m_net_revenue} / {metric/m_order_count}",
              "SELECT {metric/m_net_revenue} / (SELECT {metric/m_net_revenue} BY ALL {attribute/region})"]:
        print(q, "->", translate(q, syms))
