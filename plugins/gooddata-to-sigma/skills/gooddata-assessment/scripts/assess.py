#!/usr/bin/env python3
"""assess.py — GoodData estate migration-readiness readout (read-only).

Pulls the declarative workspace layout (no writes) and scores it against what
gooddata-to-sigma actually converts: MAQL coverage by category (reusing the
converter's own translator), insight visualization-type mix, and a per-dashboard
AUTO / HINT / MANUAL tag. Honest scoring — uses the real translator, not guesses.

Usage:
  eval "$(../gooddata-to-sigma/scripts/get-token.sh)"
  python3 assess.py --workspace <id>            # or --all
"""
import argparse, json, os, ssl, sys, urllib.request, urllib.error

# reuse the converter's MAQL translator for honest scoring
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "gooddata-to-sigma", "scripts"))
from maql import translate  # noqa: E402

_CTX = ssl.create_default_context()
if os.environ.get("GOODDATA_TLS_VERIFY") != "1":
    _CTX.check_hostname = False; _CTX.verify_mode = ssl.CERT_NONE

AUTO_VIZ = {"local:headline", "local:table", "local:pivot", "local:column", "local:bar",
            "local:line", "local:area", "local:pie", "local:donut", "local:combo",
            "local:combo2", "local:scatter", "local:bubble"}


def api(path):
    host = os.environ["GOODDATA_HOST"].rstrip("/")
    req = urllib.request.Request(host + path, headers={
        "Authorization": f"Bearer {os.environ['GOODDATA_TOKEN']}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60, context=_CTX) as r:
        return json.load(r)


def assess(ws):
    layout = api(f"/api/v1/layout/workspaces/{ws}?exclude=ACTIVITY_INFO")
    ldm = layout.get("ldm", {}) or {}; an = layout.get("analytics", {}) or {}
    syms = {"fact": {}, "attribute": {}, "metric": {}}
    for d in ldm.get("datasets", []):
        for at in d.get("attributes", []): syms["attribute"][at["id"]] = at.get("title") or at["id"]
        for f in d.get("facts", []): syms["fact"][f["id"]] = f.get("title") or f["id"]
    for m in an.get("metrics", []): syms["metric"][m["id"]] = m.get("title") or m["id"]

    metrics = an.get("metrics", []); insights = an.get("visualizationObjects", []); dashboards = an.get("analyticalDashboards", [])
    cats = {}
    for m in metrics:
        c = translate((m.get("content") or {}).get("maql", ""), syms).get("category", "UNHANDLED")
        cats[c] = cats.get(c, 0) + 1
    viz = {}; insights_by = {i["id"]: i for i in insights}
    for i in insights:
        u = i["content"].get("visualizationUrl", "?"); viz[u] = viz.get(u, 0) + 1
    flagged_viz = sum(v for k, v in viz.items() if k not in AUTO_VIZ)

    print(f"\n=== {ws} ===")
    print(f"  datasets {len(ldm.get('datasets', []))} | metrics {len(metrics)} | insights {len(insights)} | dashboards {len(dashboards)}")
    print(f"  MAQL coverage: {cats}")
    print(f"  insight types: {viz}  (non-auto: {flagged_viz})")
    # per-dashboard tag
    for d in dashboards:
        iids = [it.get("widget", {}).get("insight", {}).get("identifier", {}).get("id")
                for s in d["content"].get("layout", {}).get("sections", []) for it in s.get("items", [])]
        urls = [insights_by[i]["content"].get("visualizationUrl") for i in iids if i in insights_by]
        bad_viz = [u for u in urls if u not in AUTO_VIZ]
        tag = "UNHANDLED" if (cats.get("UNHANDLED") or bad_viz) else \
              "MANUAL" if (cats.get("CONTEXT") or cats.get("TIME_INTEL")) else \
              "HINT" if flagged_viz else "AUTO"
        print(f"  dashboard '{d.get('title')}': {len(iids)} widgets -> {tag}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default=os.environ.get("GOODDATA_WORKSPACE"))
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    if a.all:
        for w in api("/api/v1/entities/workspaces").get("data", []):
            assess(w["id"])
    elif a.workspace:
        assess(a.workspace)
    else:
        sys.exit("--workspace <id> or --all required")


if __name__ == "__main__":
    main()
