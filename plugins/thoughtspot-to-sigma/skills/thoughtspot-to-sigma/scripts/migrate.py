#!/usr/bin/env python3
"""Generalized ThoughtSpot → Sigma migration — works on ANY model, no baked ids.

  python3 migrate.py --model <TS_MODEL_ID> [--liveboard <ID> ...] [--name PREFIX]

Steps: export the model's TML → convert to a Sigma data model (convert_model.mjs)
→ POST it → discover the denormalized "<root> View" element → build a column
resolver from the model TML → for each Liveboard that reads the model, rebuild
its visualizations as a Sigma workbook off that element → apply a grid layout.

Env (all required, no hardcoded ids):
  TS_HOST, TS_TOKEN                         ThoughtSpot
  SIGMA_BASE_URL, SIGMA_API_TOKEN           Sigma
  SIGMA_CONNECTION_ID                       warehouse connection in Sigma
  SIGMA_FOLDER_ID                           destination folder
  TS_DB, TS_SCHEMA                          warehouse db/schema for the model's tables
"""
import argparse, json, os, ssl, subprocess, sys, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml, ts_lib, ts_common, apply_layouts
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda l, n: l.construct_scalar(n))

SBASE = os.environ["SIGMA_BASE_URL"]; STOK = os.environ["SIGMA_API_TOKEN"]
CONN = os.environ["SIGMA_CONNECTION_ID"]; FOLDER = os.environ["SIGMA_FOLDER_ID"]
HERE = os.path.dirname(os.path.abspath(__file__))
_SSL = ssl._create_unverified_context()

def sigma(method, path, body=None):
    r = urllib.request.Request(SBASE + path, data=(json.dumps(body).encode() if body else None),
        method=method, headers={"Authorization": "Bearer " + STOK, "Accept": "application/json",
        **({"Content-Type": "application/json"} if body else {})})
    try:
        return urllib.request.urlopen(r, context=_SSL).read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Sigma {method} {path} -> {e.code}: {e.read().decode()[:300]}")

def build_dm(model_tml, name):
    """Convert the model TML and POST a Sigma data model. Returns (dmId, denormElemId, denormName)."""
    open("/tmp/_ts_model.tml", "w").write(model_tml)
    env = {**os.environ, "TS_DB": os.environ.get("TS_DB", ""), "TS_SCHEMA": os.environ.get("TS_SCHEMA", "")}
    out = subprocess.run(["node", os.path.join(HERE, "convert_model.mjs"), "/tmp/_ts_model.tml"],
                         capture_output=True, text=True, env=env)
    if out.returncode:
        raise RuntimeError("convert failed: " + out.stderr[-300:])
    conv = json.loads(out.stdout)
    spec = conv["model"]; spec["name"] = name
    res = json.loads(sigma("POST", "/v2/dataModels/spec", {"folderId": FOLDER, **spec}))
    dm = res["dataModelId"]
    # discover the denormalized "<root> View" element from the posted DM spec
    dmspec = yaml.safe_load(sigma("GET", f"/v2/dataModels/{dm}/spec"))
    els = dmspec["pages"][0]["elements"]
    denorm = next((el for el in els if (el.get("name") or "").endswith(" View")), None)
    if not denorm:
        # no joins → no denormalized view; use the base fact element (most columns).
        denorm = max(els, key=lambda e: len(e.get("columns", [])))
    print(f"  DM {dm}  ·  denorm '{denorm['name']}' ({denorm['id']})  ·  "
          f"{conv['stats']['relationships']} rels, {conv['stats']['elements']} elements")
    return dm, denorm["id"], denorm["name"]

def migrate_liveboard(lb_id, dm, denorm_id, denorm_name, resolver, name):
    edoc, err = ts_lib.export_tml(lb_id, "LIVEBOARD")
    if err:
        raise RuntimeError("export failed: " + err)
    lb = yaml.safe_load(edoc)["liveboard"]
    specs = [ps for v in lb["visualizations"] if (ps := ts_common.parse_ts_viz(v))]
    master = ts_common.master_element(specs, resolver, dm, denorm_id, denorm_name)
    elements = [ts_common.sigma_element(s, resolver) for s in specs]
    spec = {"name": f"{name} (from ThoughtSpot)", "folderId": FOLDER, "schemaVersion": 1,
            "pages": [{"id": "p-data", "name": "Data", "elements": [master]},
                      {"id": "p-main", "name": name[:40], "elements": elements}]}
    import re
    resp = sigma("POST", "/v2/workbooks/spec", spec)
    m = re.search(r'workbookId["\s:]+([0-9a-f-]{36})', resp)
    wb = m.group(1) if m else None
    if not wb:
        raise RuntimeError("workbook POST: " + resp[:300])
    if wb:
        apply_layouts.apply(wb)
    return wb, len(specs)

def migrate_answer(ans_id, dm, denorm_id, denorm_name, resolver, name):
    """A standalone Answer is a single viz — build a one-element workbook."""
    edoc, err = ts_lib.export_tml(ans_id, "ANSWER")
    if err:
        raise RuntimeError("export failed: " + err)
    spec_v = ts_common.parse_ts_viz({"answer": yaml.safe_load(edoc)["answer"]})
    master = ts_common.master_element([spec_v], resolver, dm, denorm_id, denorm_name)
    spec = {"name": f"{name} (from ThoughtSpot)", "folderId": FOLDER, "schemaVersion": 1,
            "pages": [{"id": "p-data", "name": "Data", "elements": [master]},
                      {"id": "p-main", "name": name[:40], "elements": [ts_common.sigma_element(spec_v, resolver)]}]}
    import re
    resp = sigma("POST", "/v2/workbooks/spec", spec)
    m = re.search(r'workbookId["\s:]+([0-9a-f-]{36})', resp)
    wb = m.group(1) if m else None
    if not wb:
        raise RuntimeError("workbook POST: " + resp[:300])
    apply_layouts.apply(wb)
    return wb

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="ThoughtSpot model (LOGICAL_TABLE) id")
    ap.add_argument("--liveboard", action="append", help="specific Liveboard id(s); default = all that read the model")
    ap.add_argument("--answer", action="append", help="standalone Answer id(s) to migrate as one-element workbooks")
    ap.add_argument("--name", default=None, help="name prefix (default: the model name)")
    a = ap.parse_args()

    model_tml, err = ts_lib.export_tml(a.model, "LOGICAL_TABLE")
    if err:
        sys.exit("model export failed: " + err)
    root = yaml.safe_load(model_tml)
    root = root.get("model") or root.get("worksheet") or root
    model_name = a.name or root.get("name", "Migrated Model")
    resolver = ts_common.build_resolver(root)
    print(f"Model '{model_name}': {len(resolver)} resolvable columns")

    dm, denorm_id, denorm_name = build_dm(model_tml, f"{model_name} (from ThoughtSpot)")

    # pick Liveboards: explicit, or every Liveboard that references this model name
    if a.liveboard:
        targets = [(x, x) for x in a.liveboard]
    else:
        targets = []
        for lb in ts_lib.search("LIVEBOARD"):
            edoc, e = ts_lib.export_tml(lb["metadata_id"], "LIVEBOARD")
            if e:
                continue
            if model_name in edoc:
                targets.append((lb["metadata_id"], lb["metadata_name"]))
    print(f"Migrating {len(targets)} Liveboard(s)…")

    results = {}
    for lb_id, lb_name in targets:
        try:
            wb, n = migrate_liveboard(lb_id, dm, denorm_id, denorm_name, resolver, lb_name)
            results[lb_name] = {"liveboard": lb_id, "workbook": wb, "viz": n}
            print(f"  ✓ {lb_name[:34]:34s} WB {wb} ({n} viz)")
        except Exception as ex:
            results[lb_name] = {"error": str(ex)}
            print(f"  ✗ {lb_name[:34]:34s} {ex}")
    for ans_id in (a.answer or []):
        try:
            wb = migrate_answer(ans_id, dm, denorm_id, denorm_name, resolver, "Answer " + ans_id[:8])
            results["answer:" + ans_id] = {"answer": ans_id, "workbook": wb}
            print(f"  ✓ answer {ans_id[:8]}  WB {wb}")
        except Exception as ex:
            results["answer:" + ans_id] = {"error": str(ex)}
            print(f"  ✗ answer {ans_id[:8]}  {ex}")
    json.dump({"model": a.model, "dataModel": dm, "results": results},
              open(os.path.expanduser("~/thoughtspot-migration/migrate_out.json"), "w"), indent=2)
    print(f"\nDM: {dm}  ·  {sum(1 for r in results.values() if r.get('workbook'))}/{len(targets)} workbooks")

if __name__ == "__main__":
    main()
