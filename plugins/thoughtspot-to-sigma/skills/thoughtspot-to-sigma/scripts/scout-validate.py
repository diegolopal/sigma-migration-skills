#!/usr/bin/env python3
"""scout-validate — gap-scout validation primitive (Qlik & Power BI).

Validates a candidate Sigma formula against a real data-model element by building a
throwaway test workbook, checking the column resolves (type != "error"), and — on
success — persisting the rule to the customer-local learned-rules.yaml. Generic across
skills via --home.

    python3 scout-validate.py \
      --formula 'Avg([Master/Days To Ship])' \
      --data-model-id <dm> --element-id <denorm-elem-id> --folder-id <folder> \
      --feature 'RangeAvg' --pattern '\\bRangeAvg\\s*\\(\\s*(.+?)\\s*\\)' \
      --template 'Avg([Master/\\1])' --hint 'aggregate context only' \
      --description 'Qlik RangeAvg -> Sigma Avg' --home ~/.qlik-to-sigma

Env: SIGMA_BASE_URL, SIGMA_API_TOKEN (eval get-token.sh first).
Prints JSON: {status: validated|error, workbook_id, error, ...}. Cleans up the test workbook.
"""
import json, os, sys, ssl, urllib.request, argparse, datetime, re
_SSL = ssl._create_unverified_context()

BASE = os.environ["SIGMA_BASE_URL"]; TOK = os.environ["SIGMA_API_TOKEN"]
def api(method, path, body=None, accept_json=True):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE+path, data=data, method=method,
        headers={"Authorization":"Bearer "+TOK, "Content-Type":"application/json",
                 **({"Accept":"application/json"} if accept_json else {})})
    try:
        r = urllib.request.urlopen(req, context=_SSL); return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def dm_element_master_columns(dm_id, el_id):
    """Read the DM spec, find the element, return (elementName, [displayName,...])."""
    st, body = api("GET", f"/v2/dataModels/{dm_id}/spec")
    spec = json.loads(body)
    for pg in spec.get("pages", []):
        for el in pg.get("elements", []):
            if el.get("id") == el_id:
                src = el.get("source", {})
                name = el.get("name") or ("Custom SQL" if src.get("kind")=="sql"
                       else (src.get("path",["Element"])[-1] if src.get("kind")=="warehouse-table" else "Element"))
                cols = []
                for c in el.get("columns", []):
                    dn = c.get("name") or re.sub(r'.*/', '', c.get("formula","").strip("[]"))
                    cols.append(dn)
                return name, cols
    raise SystemExit("element not found in DM spec")

def main():
    ap = argparse.ArgumentParser()
    for f in ["formula","data-model-id","element-id","feature"]:
        ap.add_argument("--"+f, required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--pattern"); ap.add_argument("--template")
    ap.add_argument("--hint", default=""); ap.add_argument("--description", default="")
    ap.add_argument("--example-from", default="")
    ap.add_argument("--kind", default="kpi-chart", choices=["kpi-chart","table"])
    ap.add_argument("--home", default=os.path.expanduser("~/.qlik-to-sigma"))
    a = ap.parse_args()

    elem_name, cols = dm_element_master_columns(a.data_model_id, a.element_id)
    master = {"id":"m","name":"Master","kind":"table",
              "source":{"dataModelId":a.data_model_id,"elementId":a.element_id,"kind":"data-model"},
              "columns":[{"id":f"mc{i}","name":c,"formula":f"[{elem_name}/{c}]"} for i,c in enumerate(cols)]}
    if a.kind == "kpi-chart":
        test = {"id":"scout","kind":"kpi-chart","name":"scout","source":{"elementId":"m","kind":"table"},
                "columns":[{"id":"sc","formula":a.formula,"name":"scout_test"}],"value":{"columnId":"sc"}}
    else:
        test = {"id":"scout","kind":"table","name":"scout","source":{"elementId":"m","kind":"table"},
                "columns":[{"id":"sc","formula":a.formula,"name":"scout_test"}]}
    spec = {"name":f"SCOUT TEST {a.feature}","folderId":a.folder_id,"schemaVersion":1,
            "pages":[{"id":"d","name":"Data","elements":[master]},{"id":"t","name":"Test","elements":[test]}]}
    st, body = api("POST","/v2/workbooks/spec",spec)
    wb = None
    try: wb = json.loads(body).get("workbookId")
    except Exception: pass
    if not wb:
        m = re.search(r'workbookId:\s*(\S+)', body)
        if m: wb = m.group(1)
    result = {"feature":a.feature,"formula":a.formula,"workbook_id":wb}
    if not wb:
        print(json.dumps({**result,"status":"error","error":"POST failed: "+body[:200]})); return
    # check the test column's type
    st2, cbody = api("GET", f"/v2/workbooks/{wb}/elements/scout/columns")
    err = None
    try:
        colsout = json.loads(cbody)
        entries = colsout.get("entries", colsout) if isinstance(colsout, dict) else colsout
        for c in (entries or []):
            t = (c.get("type") or {})
            if (t.get("type") or t) == "error" or "error" in str(t).lower():
                err = c
    except Exception as e:
        err = {"parse": str(e), "raw": cbody[:200]}
    status = "error" if err else "validated"
    # persist on success
    if status == "validated" and a.pattern and a.template:
        os.makedirs(a.home, exist_ok=True)
        import yaml
        rp = os.path.join(a.home, "learned-rules.yaml")
        doc = yaml.safe_load(open(rp)) if os.path.exists(rp) else None
        doc = doc or {"rules":[]}
        doc["rules"].append({"feature":a.feature,"description":a.description,
            "source_pattern":a.pattern,"sigma_template":a.template,"hint":a.hint,
            "validated_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "validated_workbook":wb,"example_from":a.example_from,"confidence":"validated"})
        yaml.safe_dump(doc, open(rp,"w"), sort_keys=False)
        result["persisted_to"] = rp
    else:
        result["error_column"] = err
    # cleanup test workbook
    api("DELETE", f"/v2/files/{wb}")
    print(json.dumps({**result,"status":status}, indent=2))

if __name__ == "__main__":
    main()
