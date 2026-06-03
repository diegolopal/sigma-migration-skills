import truststore; truststore.inject_into_ssl()  # use macOS system trust (corp root CA)
import sys, json, base64, time, os, atexit, requests
import msal

CACHE = "/tmp/pbiauth/cache.bin"
_cache = msal.SerializableTokenCache()
if os.path.exists(CACHE):
    _cache.deserialize(open(CACHE).read())
atexit.register(lambda: open(CACHE, "w").write(_cache.serialize()) if _cache.has_state_changed else None)

# Well-known public client (Power BI Desktop) — no app registration needed.
CLIENT_CANDIDATES = [
    ("ea0616ba-638b-4df5-95b9-636659ae5121", "PowerBI Desktop"),
    ("04b07795-8ddb-461a-bbee-02f9e1bf7b46", "Azure CLI"),
]
AUTHORITY = "https://login.microsoftonline.com/organizations"
# Try Fabric resource first, then Power BI resource.
SCOPE_SETS = [
    ["https://api.fabric.microsoft.com/.default"],
    ["https://analysis.windows.net/powerbi/api/.default"],
]

def jwt_aud(tok):
    try:
        p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p)).get("aud")
    except Exception:
        return "?"

def get_token():
    for cid, cname in CLIENT_CANDIDATES:
        app = msal.PublicClientApplication(cid, authority=AUTHORITY, token_cache=_cache)
        for scopes in SCOPE_SETS:
            for acct in app.get_accounts():
                s = app.acquire_token_silent(scopes, account=acct)
                if s and "access_token" in s:
                    print(f"[AUTH cached] client={cname} aud={jwt_aud(s['access_token'])}", flush=True)
                    return s["access_token"]
            flow = app.initiate_device_flow(scopes=scopes)
            if "user_code" not in flow:
                print(f"[skip {cname} {scopes}] {flow.get('error_description','no device flow')}", flush=True)
                continue
            print("=" * 60, flush=True)
            print(f"CLIENT={cname}  SCOPE={scopes[0]}", flush=True)
            print(f">>> Go to: {flow['verification_uri']}", flush=True)
            print(f">>> Enter code: {flow['user_code']}", flush=True)
            print("=" * 60, flush=True)
            res = app.acquire_token_by_device_flow(flow)  # blocks until done/expired
            if "access_token" in res:
                print(f"[AUTH OK] client={cname} aud={jwt_aud(res['access_token'])}", flush=True)
                return res["access_token"]
            else:
                print(f"[AUTH FAIL {cname}] {res.get('error')}: {res.get('error_description','')[:200]}", flush=True)
    return None

def fab(tok, path):
    return requests.get(f"https://api.fabric.microsoft.com/v1{path}",
                        headers={"Authorization": f"Bearer {tok}"})

def main():
    tok = get_token()
    if not tok:
        print("NO_TOKEN — device code blocked or no client worked.", flush=True); sys.exit(2)

    r = fab(tok, "/workspaces")
    print(f"[/workspaces] {r.status_code}", flush=True)
    if r.status_code != 200:
        print(r.text[:500], flush=True); sys.exit(3)
    wss = r.json().get("value", [])
    for w in wss:
        print(f"  WS {w['id']}  {w.get('displayName')}", flush=True)

    # collect semantic models across all workspaces
    found = []
    for w in wss:
        rm = fab(tok, f"/workspaces/{w['id']}/semanticModels")
        if rm.status_code == 200:
            for m in rm.json().get("value", []):
                print(f"  MODEL ws='{w.get('displayName')}' id={m['id']} name='{m.get('displayName')}'", flush=True)
                found.append((w, m))

    # pick one named like Employee, else first
    target = next((x for x in found if "employee" in (x[1].get("displayName","" ).lower())), None) or (found[0] if found else None)
    if not target:
        print("NO_SEMANTIC_MODEL found in any accessible workspace.", flush=True); sys.exit(4)
    w, m = target
    print(f"[TARGET] ws='{w.get('displayName')}' model='{m.get('displayName')}' id={m['id']}", flush=True)

    # getDefinition (TMSL) — may be async (202 LRO)
    url = f"https://api.fabric.microsoft.com/v1/workspaces/{w['id']}/semanticModels/{m['id']}/getDefinition?format=TMSL"
    pr = requests.post(url, headers={"Authorization": f"Bearer {tok}"})
    print(f"[getDefinition] {pr.status_code}", flush=True)
    body = None
    if pr.status_code == 200:
        body = pr.json()
    elif pr.status_code == 202:
        op = pr.headers.get("Location")
        for _ in range(30):
            time.sleep(int(pr.headers.get("Retry-After", "3")))
            sr = requests.get(op, headers={"Authorization": f"Bearer {tok}"})
            st = sr.json().get("status")
            print(f"  LRO status={st}", flush=True)
            if st == "Succeeded":
                rr = requests.get(op + "/result", headers={"Authorization": f"Bearer {tok}"})
                body = rr.json(); break
            if st in ("Failed", "Undetermined"):
                print(sr.text[:500], flush=True); sys.exit(5)
    else:
        print(pr.text[:800], flush=True); sys.exit(6)

    parts = body.get("definition", {}).get("parts", [])
    print(f"[definition] {len(parts)} parts: " + ", ".join(p['path'] for p in parts), flush=True)
    for p in parts:
        data = base64.b64decode(p["payload"]).decode("utf-8", "replace")
        out = "/tmp/pbix/" + p["path"].replace("/", "__")
        open(out, "w").write(data)
    # the TMSL model file is usually 'model.bim' or 'definition/database.tmsl'
    print("WROTE definition parts to /tmp/pbix/__*. DONE.", flush=True)

main()
