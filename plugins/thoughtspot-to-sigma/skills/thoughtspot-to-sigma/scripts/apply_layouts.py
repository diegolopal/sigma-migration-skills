#!/usr/bin/env python3
"""Apply a clean grid layout to migrated Sigma workbooks.

Sigma stacks elements vertically unless a top-level spec.layout is set, and the
layout must be the LAST write (a bare spec PUT wipes it). For each workbook we
GET the spec, build a 2-page layout XML (Data page: master full-width; main
page: KPIs across the top row, other charts in a 2-wide grid), and PUT it back.

Usage: python3 apply_layouts.py            # all workbooks in the manifest
       python3 apply_layouts.py <wbId> ... # specific workbooks
Env: SIGMA_BASE_URL, SIGMA_API_TOKEN
"""
import json, os, ssl, sys, urllib.request, urllib.error
SBASE = os.environ["SIGMA_BASE_URL"]; STOK = os.environ["SIGMA_API_TOKEN"]
_SSL = ssl._create_unverified_context()
MANIFEST = os.path.expanduser("~/thoughtspot-migration/migration_manifest.json")

def req(method, path, body=None):
    r = urllib.request.Request(SBASE + path, data=(body.encode() if body else None), method=method,
        headers={"Authorization": "Bearer " + STOK, "Accept": "application/json",
                 **({"Content-Type": "application/json"} if body else {})})
    try:
        return urllib.request.urlopen(r, context=_SSL).read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read().decode()[:300]}")

def page_xml(page_id, elems):
    """KPIs across the top row (split evenly, 5 rows tall); others 2-wide, 11 rows."""
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

def build_layout(spec):
    pages = spec["pages"]
    data = next((p for p in pages if p.get("name") == "Data"), None)
    main = next((p for p in pages if p.get("name") != "Data"), None)
    lines = ['<?xml version="1.0" encoding="utf-8"?>']
    if data and data.get("elements"):
        mid = data["elements"][0]["id"]
        lines.append(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{data["id"]}">')
        lines.append(f'  <LayoutElement elementId="{mid}" gridColumn="1 / 25" gridRow="1 / 21"/>')
        lines.append('</Page>')
    elems = [{"id": e["id"], "kind": e["kind"]} for e in main["elements"]]
    lines.append(page_xml(main["id"], elems))
    return "\n".join(lines) + "\n"

def apply(wb):
    spec = json.loads(req("GET", f"/v2/workbooks/{wb}/spec"))
    xml = build_layout(spec)
    for p in spec["pages"]:
        p.pop("layout", None)
    spec["layout"] = xml
    for k in ("workbookId", "url", "ownerId", "createdBy", "updatedBy", "createdAt",
              "updatedAt", "latestDocumentVersion"):
        spec.pop(k, None)
    resp = req("PUT", f"/v2/workbooks/{wb}/spec", json.dumps(spec))
    return "workbookId" in resp

def main():
    if len(sys.argv) > 1:
        wbs = sys.argv[1:]
    else:
        m = json.load(open(MANIFEST))
        wbs = [r["workbook"] for r in m.values() if r.get("workbook")]
    ok = 0
    for wb in wbs:
        try:
            apply(wb); ok += 1; print(f"✓ laid out {wb}")
        except Exception as e:
            print(f"✗ {wb}: {e}")
    print(f"\n{ok}/{len(wbs)} workbooks laid out")

if __name__ == "__main__":
    main()
