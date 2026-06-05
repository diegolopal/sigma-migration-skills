#!/usr/bin/env python3
"""Per-visualization PNG export from ThoughtSpot — for visual parity against the
migrated Sigma workbook elements.

ThoughtSpot side (this script): POST /api/rest/2.0/report/liveboard with
file_format PNG + visualization_identifiers → PNG bytes (per viz).
Sigma side (counterpart): POST /v2/workbooks/{id}/export {elementId, format:{type:png,
pixelWidth,pixelHeight}} → poll GET /v2/query/{queryId}/download). Render both, compare side by side.

Usage:
  python3 ts_screenshot.py <LIVEBOARD_ID> [outdir]      # all viz in the liveboard
  python3 ts_screenshot.py <LIVEBOARD_ID> --viz <guid>  # one viz
Env: TS_HOST, TS_TOKEN.
"""
import os, sys, json, ssl, urllib.request, urllib.error, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml, ts_lib
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda l, n: l.construct_scalar(n))
_SSL = ssl._create_unverified_context()

def viz_png(lb_id, viz_guid, out_path):
    body = json.dumps({"metadata_identifier": lb_id, "file_format": "PNG",
                       "visualization_identifiers": [viz_guid]}).encode()
    req = urllib.request.Request(f"{ts_lib.HOST}/api/rest/2.0/report/liveboard",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {ts_lib.TOKEN}", "Content-Type": "application/json"})
    data = urllib.request.urlopen(req, context=_SSL).read()
    open(out_path, "wb").write(data)
    return len(data)

def liveboard_vizzes(lb_id):
    edoc, err = ts_lib.export_tml(lb_id, "LIVEBOARD")
    if err:
        raise RuntimeError("export failed: " + err)
    lb = yaml.safe_load(edoc)["liveboard"]
    out = []
    for v in lb.get("visualizations", []):
        if v.get("answer"):
            out.append((v.get("viz_guid") or v.get("id"), v["answer"].get("name", v.get("id"))))
    return out

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    lb_id = sys.argv[1]
    outdir = next((a for a in sys.argv[2:] if not a.startswith("--")), os.path.expanduser("~/thoughtspot-migration/png"))
    os.makedirs(outdir, exist_ok=True)
    if "--viz" in sys.argv:
        vizzes = [(sys.argv[sys.argv.index("--viz") + 1], "viz")]
    else:
        vizzes = liveboard_vizzes(lb_id)
    for guid, name in vizzes:
        safe = re.sub(r"[^\w.-]+", "_", name)[:40]
        path = os.path.join(outdir, f"{safe}.png")
        try:
            n = viz_png(lb_id, guid, path); print(f"  ✓ {name[:40]:40s} {n} bytes -> {path}")
        except Exception as e:
            print(f"  ✗ {name[:40]:40s} {e}")

if __name__ == "__main__":
    main()
