#!/usr/bin/env python3
"""Apply layout to migrated Sigma workbooks — from the Liveboard's OWN tile
geometry when available, else a clean auto grid.

Sigma stacks elements vertically unless a top-level spec.layout is set, and the
layout must be the LAST write (a bare spec PUT wipes it).

Geometry mapping (ThoughtSpot layout.tiles → Sigma grid):
  - ThoughtSpot Liveboards use a 12-column grid; Sigma uses 24 → scale x/width ×2.
  - Rows: ROW_SCALE (min 2). 1:1 row mapping makes chart bands too short and
    Sigma SUPPRESSES axis category labels / KPI titles on short bands — same
    fix as looker-to-sigma's ROW_SCALE=2 (beads-sigma-tkkv). Override with
    TS_ROW_SCALE (values < 2 are clamped to 2).

Usage: python3 apply_layouts.py [--workdir DIR]   # all workbooks in <workdir>/migrate_out.json
       python3 apply_layouts.py <wbId> ...        # specific workbooks (auto grid)
Env: SIGMA_BASE_URL, SIGMA_API_TOKEN, TS_WORKDIR (default for --workdir), TS_ROW_SCALE
"""
import argparse, json, os, ssl, sys, urllib.request, urllib.error
_SSL = ssl._create_unverified_context()

TS_GRID_COLS = 12                                   # ThoughtSpot Liveboard grid
COL_SCALE = 24 // TS_GRID_COLS                      # → Sigma's 24-col grid
ROW_SCALE = max(2, int(os.environ.get("TS_ROW_SCALE", "2") or 2))

def req(method, path, body=None):
    base = os.environ["SIGMA_BASE_URL"]; tok = os.environ["SIGMA_API_TOKEN"]
    r = urllib.request.Request(base + path, data=(body.encode() if body else None), method=method,
        headers={"Authorization": "Bearer " + tok, "Accept": "application/json",
                 **({"Content-Type": "application/json"} if body else {})})
    try:
        return urllib.request.urlopen(r, context=_SSL).read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read().decode()[:300]}")

def tiles_page_xml(page_id, tiles):
    """ThoughtSpot tile geometry → Sigma grid. tiles: [{element_id,x,y,width,height}]
    in TS 12-col units."""
    out = [f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">']
    for t in tiles:
        c0 = t["x"] * COL_SCALE + 1
        c1 = min(t["x"] + t["width"], TS_GRID_COLS) * COL_SCALE + 1
        r0 = t["y"] * ROW_SCALE + 1
        r1 = (t["y"] + t["height"]) * ROW_SCALE + 1
        out.append(f'  <LayoutElement elementId="{t["element_id"]}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>')
    out.append("</Page>")
    return "\n".join(out)

def page_xml(page_id, elems):
    """Auto grid fallback (no TML geometry): KPIs across the top row (split
    evenly, 5 rows tall); others 2-wide, 11 rows."""
    kpis = [e for e in elems if e["kind"] == "kpi-chart"]
    charts = [e for e in elems if e["kind"] not in ("kpi-chart",)]
    out = [f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">']
    if kpis:
        w = 24 // len(kpis)
        for i, e in enumerate(kpis):
            c0 = 1 + i * w; c1 = (c0 + w) if i < len(kpis) - 1 else 25
            out.append(f'  <LayoutElement elementId="{e["id"]}" gridColumn="{c0} / {c1}" gridRow="1 / 6"/>')
    row = 6
    for i in range(0, len(charts), 2):
        pair = charts[i:i + 2]
        for j, e in enumerate(pair):
            c0 = 1 if j == 0 else 13
            c1 = 13 if (j == 0 and len(pair) > 1) else 25
            out.append(f'  <LayoutElement elementId="{e["id"]}" gridColumn="{c0} / {c1}" gridRow="{row} / {row+11}"/>')
        row += 11
    out.append("</Page>")
    return "\n".join(out)

def build_layout(spec, tiles=None):
    pages = spec["pages"]
    data = next((p for p in pages if p.get("name") == "Data"), None)
    main = next((p for p in pages if p.get("name") != "Data"), None)
    lines = ['<?xml version="1.0" encoding="utf-8"?>']
    if data and data.get("elements"):
        mid = data["elements"][0]["id"]
        lines.append(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{data["id"]}">')
        lines.append(f'  <LayoutElement elementId="{mid}" gridColumn="1 / 25" gridRow="1 / 21"/>')
        lines.append('</Page>')
    if tiles:
        lines.append(tiles_page_xml(main["id"], tiles))
    else:
        elems = [{"id": e["id"], "kind": e["kind"]} for e in main["elements"]]
        lines.append(page_xml(main["id"], elems))
    return "\n".join(lines) + "\n"

def apply(wb, tiles=None):
    spec = json.loads(req("GET", f"/v2/workbooks/{wb}/spec"))
    xml = build_layout(spec, tiles=tiles)
    for p in spec["pages"]:
        p.pop("layout", None)
    spec["layout"] = xml
    for k in ("workbookId", "url", "ownerId", "createdBy", "updatedBy", "createdAt",
              "updatedAt", "latestDocumentVersion"):
        spec.pop(k, None)
    resp = req("PUT", f"/v2/workbooks/{wb}/spec", json.dumps(spec))
    return "workbookId" in resp

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", default=None, help="dir holding migrate_out.json (default $TS_WORKDIR or ./ts-migration)")
    ap.add_argument("workbooks", nargs="*", help="specific workbook ids (auto grid; skips the manifest)")
    a = ap.parse_args()
    if a.workbooks:
        jobs = [(wb, None) for wb in a.workbooks]
    else:
        wd = os.path.abspath(os.path.expanduser(a.workdir or os.environ.get("TS_WORKDIR")
                             or os.path.join(os.getcwd(), "ts-migration")))
        manifest = os.path.join(wd, "migrate_out.json")
        m = json.load(open(manifest))
        results = m.get("results", m)          # new manifest nests under "results"
        jobs = [(r["workbook"], r.get("tiles")) for r in results.values() if r.get("workbook")]
    ok = 0
    for wb, tiles in jobs:
        try:
            apply(wb, tiles=tiles); ok += 1
            print(f"✓ laid out {wb} ({'TML tiles' if tiles else 'auto grid'})")
        except Exception as e:
            print(f"✗ {wb}: {e}")
    print(f"\n{ok}/{len(jobs)} workbooks laid out")

if __name__ == "__main__":
    main()
