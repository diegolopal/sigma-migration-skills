#!/usr/bin/env python3
"""gen-denorm-sql — build the denormalized SQL element from a reconcile map.

    python3 gen-denorm-sql.py --reconcile reconcile.json --database CSA --schema TJ [--out denorm.json]

Consumes reconcile-columns.py output and auto-generates the Sigma data-model SQL element:
  - SELECT writes `<realColumn> AS <qlikField>` for every field (preserving Qlik names while
    pointing at real warehouse columns — the rename reconciliation)
  - infers LEFT JOINs: the fact (table named *FACT or with the most *_KEY fields) joined to
    each dim on a shared Qlik *_KEY field name (mapped to each side's real column)
Emits a ready-to-POST Sigma element `{kind:table, source:{kind:sql,connectionId,statement}, columns}`
with `[Custom SQL/<RAW alias>]` formulas. Drops this into build-sigma-dm.py's element list.
"""
import re, json, argparse, secrets, string, os

def disp(c): return " ".join(w.capitalize() for w in c.split("_"))
def nid(n=10): return "".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(n))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reconcile", required=True)
    ap.add_argument("--database", required=True); ap.add_argument("--schema", required=True)
    ap.add_argument("--connection", default=os.environ.get("SIGMA_CONNECTION_ID",""),
                    help="your Sigma warehouse connection id (or set SIGMA_CONNECTION_ID)")
    ap.add_argument("--out", default="denorm-element.json")
    a = ap.parse_args()
    tables = json.load(open(a.reconcile))
    def wh(t): return f'{a.database}.{a.schema}.{re.sub(r"\.csv$","",t["sourceTable"],flags=re.I)}'
    keyfields = lambda t: [f["qlikField"] for f in t["fields"] if f["qlikField"].upper().endswith("_KEY")]
    # fact = name has FACT, else most *_KEY fields
    fact = next((t for t in tables if "FACT" in t["qlikTable"].upper()), None) \
        or max(tables, key=lambda t: len(keyfields(t)))
    dims = [t for t in tables if t is not fact]
    factkeys = set(k.upper() for k in keyfields(fact))
    real = lambda t, q: next(f["realColumn"] for f in t["fields"] if f["qlikField"] == q)

    select, joins, alias = [], [], {}
    # fact columns (exclude raw keys we only use for joins? keep all non-key + measures; keep keys too is fine)
    for f in fact["fields"]:
        if f.get("isExpression"): continue
        if f["realColumn"] == "*": continue
        select.append(f'f.{f["realColumn"]} AS {f["qlikField"]}')
    a_i = 0
    for d in dims:
        # find join key: a *_KEY qlikField in this dim that the fact also has
        jk = next((k for k in keyfields(d) if k.upper() in factkeys), None)
        al = chr(ord('a') + a_i); a_i += 1; alias[d["qlikTable"]] = al
        if jk:
            joins.append(f'LEFT JOIN {wh(d)} {al} ON f.{real(fact, jk)} = {al}.{real(d, jk)}')
        # dim descriptive columns (skip its own key columns to avoid dup)
        for f in d["fields"]:
            if f.get("isExpression") or f["realColumn"] == "*": continue
            if f["qlikField"].upper().endswith("_KEY"): continue
            select.append(f'{al}.{f["realColumn"]} AS {f["qlikField"]}')
    sql = "SELECT\n  " + ",\n  ".join(select) + f"\nFROM {wh(fact)} f\n" + "\n".join(joins)

    # element columns: [Custom SQL/<ALIAS>] where ALIAS is the qlik field name (the SQL output col)
    cols, order = [], []
    seen = set()
    for line in select:
        qn = line.split(" AS ")[-1].strip()
        if qn in seen: continue
        seen.add(qn)
        cidv = nid(); cols.append({"id": cidv, "name": disp(qn), "formula": f"[Custom SQL/{qn}]"}); order.append(cidv)
    element = {"id": nid(), "kind": "table",
               "source": {"connectionId": a.connection, "kind": "sql", "statement": sql},
               "columns": cols, "order": order}
    json.dump({"element": element, "sql": sql}, open(a.out, "w"), indent=2)
    print("fact:", fact["qlikTable"], "| dims:", [d["qlikTable"] for d in dims], "| columns:", len(cols))
    print("--- generated denorm SQL ---")
    print(sql)

if __name__ == "__main__":
    main()
