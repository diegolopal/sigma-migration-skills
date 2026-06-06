#!/usr/bin/env python3
"""Phase 1 discovery for quicksight-to-sigma.

Pulls a QuickSight analysis (or dashboard) definition + its datasets + data sources
via the AWS CLI, and writes a normalized signals.json the convert + workbook phases consume.

Enterprise edition required for the *-definition calls (Standard edition rejects them).
QuickSight's identity region (often us-east-1) is where the resources live — pass --region accordingly.

Usage:
  python3 scripts/quicksight-discover.py \
    --account-id 153722385948 --region us-east-1 --profile pivot \
    --analysis-id orders-overview --out-dir ~/quicksight-migration/orders-overview
"""
import argparse, json, os, subprocess, sys


def aws(args, acct, region, profile):
    cmd = ["aws", "quicksight"] + args + ["--aws-account-id", acct, "--region", region, "--output", "json"]
    if profile:
        cmd += ["--profile", profile]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "aws call failed: " + " ".join(args[:2]))
    return json.loads(p.stdout)


def arn_id(arn):
    return arn.rsplit("/", 1)[-1]


def field_columns(inner):
    """Shallow-walk a visual's ChartConfiguration collecting referenced ColumnNames."""
    cols = []
    def walk(o):
        if isinstance(o, dict):
            col = o.get("Column")
            if isinstance(col, dict) and "ColumnName" in col:
                cols.append(col["ColumnName"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(inner.get("ChartConfiguration", {}))
    # dedupe, preserve order
    seen, out = set(), []
    for c in cols:
        if c not in seen:
            seen.add(c); out.append(c)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--account-id", required=True)
    ap.add_argument("--region", required=True)
    ap.add_argument("--profile")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--analysis-id")
    g.add_argument("--dashboard-id")
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()

    out = os.path.expanduser(a.out_dir)
    os.makedirs(os.path.join(out, "datasets"), exist_ok=True)
    os.makedirs(os.path.join(out, "datasources"), exist_ok=True)

    # 1. the analysis / dashboard definition
    if a.analysis_id:
        d = aws(["describe-analysis-definition", "--analysis-id", a.analysis_id], a.account_id, a.region, a.profile)
        src_kind, src_id = "analysis", a.analysis_id
    else:
        d = aws(["describe-dashboard-definition", "--dashboard-id", a.dashboard_id], a.account_id, a.region, a.profile)
        src_kind, src_id = "dashboard", a.dashboard_id
    name = d.get("Name")
    defn = d["Definition"]
    json.dump(d, open(os.path.join(out, "analysis.json"), "w"), indent=2)

    # 2. datasets referenced by the definition
    ds_meta, src_arns = [], set()
    for decl in defn.get("DataSetIdentifierDeclarations", []):
        ident, ds_id = decl["Identifier"], arn_id(decl["DataSetArn"])
        ds = aws(["describe-data-set", "--data-set-id", ds_id], a.account_id, a.region, a.profile)
        json.dump(ds, open(os.path.join(out, "datasets", ds_id + ".json"), "w"), indent=2)
        dso = ds["DataSet"]
        for ptv in (dso.get("PhysicalTableMap") or {}).values():
            for v in ptv.values():
                if isinstance(v, dict) and v.get("DataSourceArn"):
                    src_arns.add(v["DataSourceArn"])
        ds_meta.append({"identifier": ident, "dataSetId": ds_id, "name": dso.get("Name"),
                        "importMode": dso.get("ImportMode"),
                        "columns": [c.get("Name") for c in dso.get("OutputColumns", [])]})

    # 3. data sources (type tells us Snowflake/Redshift/S3/etc.)
    src_meta = []
    for arn in sorted(src_arns):
        sid = arn_id(arn)
        try:
            s = aws(["describe-data-source", "--data-source-id", sid], a.account_id, a.region, a.profile)
            json.dump(s, open(os.path.join(out, "datasources", sid + ".json"), "w"), indent=2)
            so = s["DataSource"]
            src_meta.append({"dataSourceId": sid, "name": so.get("Name"), "type": so.get("Type")})
        except RuntimeError as e:
            src_meta.append({"dataSourceId": sid, "name": None, "type": "UNKNOWN", "error": str(e)[:120]})

    # 4. signals: per-sheet visuals + calc fields + params
    sheets = []
    for sh in defn.get("Sheets", []):
        vis = []
        for v in sh.get("Visuals", []):
            (vtype, inner), = v.items()
            t = inner.get("Title", {})
            title = (t.get("FormatText") or {}).get("PlainText") if isinstance(t, dict) else None
            vis.append({"type": vtype, "visualId": inner.get("VisualId"),
                        "title": title, "columns": field_columns(inner)})
        sheets.append({"sheetId": sh.get("SheetId"), "name": sh.get("Name"), "visuals": vis})

    calc = [{"name": c.get("Name"), "expression": c.get("Expression"), "dataset": c.get("DataSetIdentifier")}
            for c in defn.get("CalculatedFields", [])]
    params = [{"name": (list(p.values())[0] or {}).get("Name")} for p in defn.get("ParameterDeclarations", [])]

    signals = {"source": {"kind": src_kind, "id": src_id, "name": name},
               "datasets": ds_meta, "dataSources": src_meta,
               "calculatedFields": calc, "parameters": params, "sheets": sheets}
    json.dump(signals, open(os.path.join(out, "signals.json"), "w"), indent=2)

    # summary
    print(f"Discovered {src_kind} '{name}' → {out}")
    print(f"  datasets: {len(ds_meta)}  | data sources: {[s['type'] for s in src_meta]}")
    print(f"  calc fields: {len(calc)} | parameters: {len(params)}")
    for s in sheets:
        kinds = ", ".join(v["type"] for v in s["visuals"])
        print(f"  sheet '{s['name']}': {len(s['visuals'])} visuals — {kinds}")


if __name__ == "__main__":
    main()
