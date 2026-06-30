#!/usr/bin/env python3
"""discover.py — GoodData Cloud / .CN declarative workspace export.

Phase 1 of the migration: pull the entire workspace (LDM + analytics model) via
the declarative layout API and summarize it. This is the FIRST thing to validate
against a live trial workspace before any conversion is built.

Usage:
  eval "$(./get-token.sh)"
  python3 discover.py --workspace <id> [--out workspace_layout.json]
  python3 discover.py --list                 # list all workspaces

Env: GOODDATA_HOST, GOODDATA_TOKEN (see get-token.sh).

Status: functional, NOT yet run against a live workspace. Endpoints/shape per
refs/gooddata-api.md (docs-verified June 2026); confirm field paths on first
live run and adjust the summary extractors.
"""
import argparse, json, os, ssl, sys, urllib.request, urllib.error

# Some GoodData trial/corp endpoints present a CA chain Python rejects
# ("CA cert does not include key usage extension"); fall back to an unverified
# context. Set GOODDATA_TLS_VERIFY=1 to force strict verification.
_CTX = ssl.create_default_context()
if os.environ.get("GOODDATA_TLS_VERIFY") != "1":
    _CTX.check_hostname = False
    _CTX.verify_mode = ssl.CERT_NONE


def api(path):
    host = os.environ["GOODDATA_HOST"].rstrip("/")
    req = urllib.request.Request(host + path)
    req.add_header("Authorization", f"Bearer {os.environ['GOODDATA_TOKEN']}")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60, context=_CTX) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"GET {path} -> {e.code}: {e.read()[:300].decode(errors='replace')}")


def summarize(layout):
    ldm = layout.get("ldm", {}) or {}
    an = layout.get("analytics", {}) or {}
    datasets = ldm.get("datasets", []) or []
    metrics = an.get("metrics", []) or []
    insights = an.get("visualizationObjects", []) or []
    dashboards = an.get("analyticalDashboards", []) or []
    print(f"  datasets:    {len(datasets)}")
    print(f"  dateInstances:{len(ldm.get('dateInstances', []) or [])}")
    print(f"  metrics:     {len(metrics)}  (MAQL — the translation surface)")
    print(f"  insights:    {len(insights)}")
    print(f"  dashboards:  {len(dashboards)}")
    # crude MAQL-construct histogram to size the translator gap
    import re
    kw = {}
    for m in metrics:
        maql = ((m.get("content") or {}).get("maql") or "")
        for k in ("BY ALL", "WITHIN", " BY ", "WHERE", "FOR PREVIOUS", "FOR NEXT", "TOP(", "BOTTOM("):
            if k.strip() and k in maql.upper():
                kw[k.strip()] = kw.get(k.strip(), 0) + 1
    if kw:
        print("  MAQL keywords seen:", ", ".join(f"{k}×{v}" for k, v in sorted(kw.items(), key=lambda x: -x[1])))
    # insight viz-type histogram
    viz = {}
    for i in insights:
        url = ((i.get("content") or {}).get("visualizationUrl") or "?")
        viz[url] = viz.get(url, 0) + 1
    if viz:
        print("  insight types:", ", ".join(f"{k}×{v}" for k, v in sorted(viz.items(), key=lambda x: -x[1])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default=os.environ.get("GOODDATA_WORKSPACE"))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out", default="workspace_layout.json")
    a = ap.parse_args()

    if a.list:
        d = api("/api/v1/layout/workspaces")
        for w in (d.get("workspaces") or d.get("workspaceDataFilters") or []):
            print(w.get("id"), "|", w.get("name") or (w.get("meta") or {}).get("title", ""))
        return

    if not a.workspace:
        sys.exit("--workspace <id> required (or set GOODDATA_WORKSPACE)")

    layout = api(f"/api/v1/layout/workspaces/{a.workspace}?exclude=ACTIVITY_INFO")
    with open(a.out, "w") as f:
        json.dump(layout, f, indent=2)
    print(f"=== workspace {a.workspace} → {a.out} ===")
    summarize(layout)


if __name__ == "__main__":
    main()
