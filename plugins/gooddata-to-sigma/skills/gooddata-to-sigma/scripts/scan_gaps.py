#!/usr/bin/env python3
"""scan_gaps.py — gap-scout for MAQL coverage.

Runs the MAQL translator over every metric in a workspace export and reports
coverage by category (AUTO / TIME_INTEL / CONTEXT / UNHANDLED), so MAQL
translation coverage is *measured*, not assumed — and appends UNHANDLED
constructs to a learned-rules file for follow-up (flag, never fake).

Usage:
  python3 scan_gaps.py --workspace gd_workspace.json [--rules learned-rules.json]
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from maql import translate

CATEGORY_NOTE = {
    "AUTO": "translated to a Sigma data-model metric",
    "TIME_INTEL": "workbook-level: Sigma DateLookback in a date-grouped element",
    "CONTEXT": "workbook-level: Sigma grouping / Level-scoped aggregate",
    "UNHANDLED": "no translation — needs review (learned-rules)",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--rules", default="learned-rules.json")
    a = ap.parse_args()
    layout = json.load(open(a.workspace))
    ldm = layout.get("ldm", {}) or {}; an = layout.get("analytics", {}) or {}
    syms = {"fact": {}, "attribute": {}, "metric": {}}
    for d in ldm.get("datasets", []):
        for at in d.get("attributes", []): syms["attribute"][at["id"]] = at.get("title") or at["id"]
        for f in d.get("facts", []): syms["fact"][f["id"]] = f.get("title") or f["id"]
    for m in an.get("metrics", []): syms["metric"][m["id"]] = m.get("title") or m["id"]

    metrics = an.get("metrics", [])
    by_cat = {}; unhandled = []
    for m in metrics:
        res = translate((m.get("content") or {}).get("maql", ""), syms)
        cat = res.get("category", "UNHANDLED")
        by_cat.setdefault(cat, []).append(m["id"])
        if cat == "UNHANDLED":
            unhandled.append({"metric": m["id"], "maql": (m.get("content") or {}).get("maql"), "reason": res["reason"]})

    total = len(metrics) or 1
    auto = len(by_cat.get("AUTO", []))
    print(f"=== MAQL coverage: {len(metrics)} metrics ===")
    for cat in ("AUTO", "TIME_INTEL", "CONTEXT", "UNHANDLED"):
        ids = by_cat.get(cat, [])
        if ids:
            print(f"  {cat:10} {len(ids):3}  ({CATEGORY_NOTE[cat]})")
            for i in ids: print(f"       - {i}")
    print(f"  ---\n  data-model-AUTO: {auto}/{len(metrics)} ({100*auto//total}%); "
          f"workbook-portable: {len(by_cat.get('TIME_INTEL', []))+len(by_cat.get('CONTEXT', []))}; "
          f"unhandled: {len(by_cat.get('UNHANDLED', []))}")

    if unhandled:
        prev = json.load(open(a.rules)) if os.path.exists(a.rules) else []
        seen = {r["maql"] for r in prev}
        prev += [u for u in unhandled if u["maql"] not in seen]
        json.dump(prev, open(a.rules, "w"), indent=2)
        print(f"  appended {len(unhandled)} unhandled construct(s) -> {a.rules}")


if __name__ == "__main__":
    main()
