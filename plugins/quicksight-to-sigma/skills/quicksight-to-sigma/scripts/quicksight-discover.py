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

Offline / fixture mode (no AWS account or CLI needed — drives the same
signals.json off describe-shaped JSON files already on disk, e.g. the skill's
fixtures/ or a customer's exported definitions):

  python3 scripts/quicksight-discover.py \
    --from-fixtures plugins/.../fixtures --out-dir /tmp/qs-orders
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


def load_fixtures(fdir):
    """Read describe-shaped JSONs from a dir: one analysis/dashboard definition
    (top-level "Definition") + one or more datasets (top-level "DataSet")."""
    analysis, datasets = None, []
    for fn in sorted(os.listdir(fdir)):
        if not fn.endswith(".json"):
            continue
        try:
            j = json.load(open(os.path.join(fdir, fn)))
        except (ValueError, OSError):
            continue
        if isinstance(j, dict) and "Definition" in j:
            analysis = j
        elif isinstance(j, dict) and "DataSet" in j:
            datasets.append(j)
    if analysis is None:
        sys.exit(f"--from-fixtures: no analysis/dashboard definition JSON (top-level 'Definition') in {fdir}")
    return analysis, datasets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--account-id")
    ap.add_argument("--region")
    ap.add_argument("--profile")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--analysis-id")
    g.add_argument("--dashboard-id")
    ap.add_argument("--from-fixtures", help="dir of describe-shaped JSONs — offline mode, no AWS calls")
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    offline = bool(a.from_fixtures)
    if not offline and not (a.analysis_id or a.dashboard_id):
        ap.error("need --analysis-id or --dashboard-id (or --from-fixtures)")
    if not offline and not (a.account_id and a.region):
        ap.error("--account-id and --region are required for live discovery")

    out = os.path.expanduser(a.out_dir)
    os.makedirs(os.path.join(out, "datasets"), exist_ok=True)
    os.makedirs(os.path.join(out, "datasources"), exist_ok=True)

    fixture_ds = []
    # 1. the analysis / dashboard definition
    if offline:
        d, fixture_ds = load_fixtures(os.path.expanduser(a.from_fixtures))
        src_kind = "dashboard" if d.get("DashboardId") else "analysis"
        src_id = d.get("AnalysisId") or d.get("DashboardId") or "fixture"
    elif a.analysis_id:
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
    fixture_by_id = {ds["DataSet"].get("DataSetId"): ds for ds in fixture_ds}
    for decl in defn.get("DataSetIdentifierDeclarations", []):
        ident, ds_id = decl["Identifier"], arn_id(decl["DataSetArn"])
        if offline:
            ds = fixture_by_id.get(ds_id)
            if ds is None:
                print(f"  WARN: no fixture dataset JSON for '{ds_id}' — skipping", file=sys.stderr)
                continue
        else:
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
        if offline:
            src_meta.append({"dataSourceId": sid, "name": None, "type": "OFFLINE-FIXTURE"})
            continue
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
