#!/usr/bin/env python3
"""reconcile-columns — auto-derive the Qlik-field → warehouse-column map from the load script.

    python3 reconcile-columns.py --script discovery/script.qvs [--out reconcile.json]

Phase 3 of qlik-to-sigma. The Qlik LOAD script renames warehouse columns
(`ORDER_STORE_KEY AS STORE_KEY`, `REGION AS CUSTOMER_REGION`) — so when you build the
Sigma data model against the real warehouse, you must point columns at the REAL column
while keeping the Qlik field name. This parses the load script's `AS` clauses + the
source table per `LOAD` block and emits that mapping, so the DM build (or the denormalized
SQL element) can use `<real col> AS <qlik name>` faithfully.

Output per Qlik table:
  { qlikTable, sourceTable, fields:[{ qlikField, realColumn, renamed }] }

Handles: `SQL SELECT ... FROM db.schema.TABLE;` (real migration) and
`FROM [lib://Conn/FILE.csv]` (CSV fixture). RESIDENT/INLINE are flagged, not resolved.
"""
import re, json, argparse, sys

BLOCK = re.compile(
    r'(\w+)\s*:\s*\n\s*LOAD\b(.*?);\s*(?:\n|$)', re.IGNORECASE | re.DOTALL)
SOURCE = re.compile(
    r'\bSQL\s+SELECT\b.*?\bFROM\s+([A-Za-z0-9_."]+(?:\.[A-Za-z0-9_."]+)*)'  # SQL FROM db.schema.table
    r'|\bFROM\s+\[lib://[^/]+/([^\]]+)\]'                                    # lib CSV
    r'|\bRESIDENT\s+(\w+)|\b(INLINE|AUTOGENERATE)\b',
    re.IGNORECASE | re.DOTALL)

def parse(qvs):
    out = []
    for m in BLOCK.finditer(qvs):
        name, body = m.group(1), m.group(2)
        # split source clause off the field list
        src_m = SOURCE.search(body)
        field_part = body[:src_m.start()] if src_m else body
        sql_from, lib_file, resident, special = (src_m.groups() if src_m else (None, None, None, None))
        source = (sql_from or "").strip('"') or (lib_file or "") or (f"RESIDENT {resident}" if resident else "") or (special or "?")
        fields = []
        for tok in field_part.split(","):
            tok = tok.strip().strip(";").strip()
            if not tok or tok.upper() == "LOAD": continue
            tok = re.sub(r'^LOAD\b', '', tok, flags=re.IGNORECASE).strip()
            am = re.search(r'^(.*?)\s+AS\s+"?([A-Za-z0-9_]+)"?$', tok, re.IGNORECASE)
            if am:
                real = am.group(1).strip().strip('"'); qlik = am.group(2)
                # real may be an expression; flag if not a plain column
                renamed = real.upper() != qlik.upper()
                fields.append({"qlikField": qlik, "realColumn": real, "renamed": renamed,
                               "isExpression": not re.match(r'^[A-Za-z0-9_]+$', real)})
            else:
                col = tok.strip('"')
                if re.match(r'^[A-Za-z0-9_*]+$', col):
                    fields.append({"qlikField": col, "realColumn": col, "renamed": False, "isExpression": False})
        if fields:
            out.append({"qlikTable": name, "sourceTable": source, "fields": fields})
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True)
    ap.add_argument("--out", default="reconcile.json")
    a = ap.parse_args()
    tables = parse(open(a.script).read())
    json.dump(tables, open(a.out, "w"), indent=2)
    print(f"tables={len(tables)} -> {a.out}")
    for t in tables:
        ren = [f for f in t["fields"] if f["renamed"]]
        print(f"  {t['qlikTable']:14} src={t['sourceTable']:30} fields={len(t['fields']):2}  renamed={len(ren)}")
        for f in ren:
            tag = " (EXPR)" if f.get("isExpression") else ""
            print(f"      {f['qlikField']}  <-  {f['realColumn']}{tag}")

if __name__ == "__main__":
    main()
