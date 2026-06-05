#!/usr/bin/env python3
"""ThoughtSpot migration-readiness assessment.

Inventories the instance (models/worksheets + Liveboards + Answers +
connections), and for every exportable Liveboard scores migration complexity
from its visualizations: viz count, chart-type mix, and the model(s) it reads.
Produces a value/cost-style shortlist for a ThoughtSpot -> Sigma migration.

Chart types the thoughtspot-to-sigma pipeline handles today map to Sigma
kpi/bar/line/table; pie/area/stacked are supported in Sigma and migrate as
their nearest kind. Anything else is flagged for review.

Env: TS_HOST, TS_TOKEN.
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml, ts_lib

# ThoughtSpot TML uses bare `=` (e.g. `oper: =`) which PyYAML reads as the
# special value tag — treat it as a plain string.
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value",
                                lambda loader, node: loader.construct_scalar(node))

SUPPORTED = {"KPI", "COLUMN", "BAR", "LINE", "PIE", "TABLE", "ADVANCED_COLUMN",
             "STACKED_COLUMN", "STACKED_BAR", "AREA", "STACKED_AREA", "LINE_COLUMN"}

def liveboard_profile(lb_id, name):
    edoc, err = ts_lib.export_tml(lb_id, "LIVEBOARD")
    if err:
        return {"id": lb_id, "name": name, "exportable": False, "note": err.split(":")[0]}
    try:
        lb = yaml.safe_load(edoc)["liveboard"]
    except Exception as e:
        return {"id": lb_id, "name": name, "exportable": False, "note": f"parse: {type(e).__name__}"}
    types, models, unsupported = {}, set(), []
    for v in lb.get("visualizations", []):
        a = v.get("answer")
        if not a:
            continue
        ct = (a.get("chart") or {}).get("type") or ("TABLE" if a.get("display_mode") == "TABLE_MODE" else "?")
        types[ct] = types.get(ct, 0) + 1
        if ct not in SUPPORTED:
            unsupported.append(ct)
        for t in a.get("tables", []):
            models.add(t.get("name"))
    nviz = sum(types.values())
    # crude complexity: viz count + distinct chart kinds + #models touched
    complexity = nviz + 2 * len(types) + 3 * len(models)
    return {"id": lb_id, "name": name, "exportable": True, "viz": nviz,
            "chart_types": types, "models": sorted(models),
            "unsupported": sorted(set(unsupported)), "complexity": complexity}

def get_usage(days_query="[Timestamp].'last 12 months'"):
    """Per-object usage from the TS: BI Server system worksheet (ThoughtSpot's
    built-in usage/activity log): {object_name: {views, users}}. BI Server logs
    interactive views only, so API-created-but-never-viewed content reads 0.
    Returns ({}, reason) if BI Server is absent/empty."""
    bi = next((x for x in ts_lib.search("LOGICAL_TABLE") if x["metadata_name"] == "TS: BI Server"), None)
    if not bi:
        return {}, "TS: BI Server worksheet not found"
    bid = bi["metadata_id"]
    try:
        views = ts_lib.searchdata(
            f"[Answer Book Name] count [User Action] unique count [User] "
            f"[User Action] != 'invalid' {days_query}", bid, record_size=500)
    except Exception as e:
        return {}, f"BI Server query failed: {e}"
    out = {}
    for row in views["data_rows"]:
        name = row[0]
        if name is None:
            continue
        out[name] = {"views": row[1], "users": row[2]}
    return out, ("no recorded views in window" if not out else None)

def main():
    models = [x for x in ts_lib.search("LOGICAL_TABLE")
              if x.get("metadata_header", {}).get("type") in ("WORKSHEET", "MODEL")]
    lbs = ts_lib.search("LIVEBOARD")
    answers = ts_lib.search("ANSWER")
    conns = ts_lib.search("CONNECTION")

    print("="*64)
    print("THOUGHTSPOT MIGRATION ASSESSMENT")
    print("="*64)
    print(f"Inventory: {len(conns)} connection(s), {len(models)} models/worksheets, "
          f"{len(lbs)} Liveboards, {len(answers)} Answers\n")

    profiles = [liveboard_profile(x["metadata_id"], x["metadata_name"]) for x in lbs]
    exportable = [p for p in profiles if p.get("exportable")]
    locked = [p for p in profiles if not p.get("exportable")]

    # Usage (ThoughtSpot's built-in activity log) — attach views/users per object.
    usage, usage_note = get_usage()
    for p in profiles:
        u = usage.get(p["name"]) or usage.get(p["name"].replace(" (TS)", ""))
        p["views"] = (u or {}).get("views", 0)
        p["users"] = (u or {}).get("users", 0)
    total_views = sum(p.get("views", 0) for p in profiles)
    print("USAGE (TS: BI Server — interactive views; value signal for the shortlist):")
    if total_views == 0:
        print(f"  ⚠ no recorded usage in window ({usage_note or 'BI Server empty'}). "
              f"On a populated instance this yields per-object views + distinct users.\n")
    else:
        for p in sorted(profiles, key=lambda p: -p.get("views", 0))[:15]:
            if p.get("views"):
                print(f"  {p['name'][:36]:36s} {p['views']:>6} views  {p['users']:>3} users")
        print()

    print(f"Liveboards readable via API: {len(exportable)}/{len(profiles)} "
          f"({len(locked)} system/locked, not migratable by this identity)\n")

    # value/cost ranking: value = interactive views, cost = complexity.
    for p in exportable:
        p["value_cost"] = round(p.get("views", 0) / (1 + p["complexity"]), 3)
    ranked = (sorted(exportable, key=lambda p: -p["value_cost"]) if total_views
              else sorted(exportable, key=lambda p: p["complexity"]))
    print("MIGRATION SHORTLIST (%s):" % ("value/cost — migrate high-value, low-effort first"
                                         if total_views else "easiest first; no usage yet, so by effort"))
    print(f"  {'Liveboard':32s} {'viz':>3s} {'kinds':>5s} {'cx':>4s} {'v/c':>6s}  chart types")
    for p in ranked:
        flag = "  ⚠ " + ",".join(p["unsupported"]) if p["unsupported"] else ""
        print(f"  {p['name'][:32]:32s} {p['viz']:>3d} {len(p['chart_types']):>5d} {p['complexity']:>4d} "
              f"{p['value_cost']:>6} {','.join(f'{k}×{v}' for k,v in p['chart_types'].items())}{flag}")

    all_types = {}
    for p in exportable:
        for k, v in p["chart_types"].items():
            all_types[k] = all_types.get(k, 0) + v
    unsup = {k: v for k, v in all_types.items() if k not in SUPPORTED}
    total_viz = sum(all_types.values())
    cov = 100 * (total_viz - sum(unsup.values())) / total_viz if total_viz else 100
    print(f"\nChart-type coverage: {cov:.1f}%  ({total_viz} viz across exportable Liveboards)")
    print(f"  all types: {all_types}")
    if unsup:
        print(f"  ⚠ needs review: {unsup}")
    models_used = sorted({m for p in exportable for m in p["models"]})
    print(f"\nModels referenced by exportable Liveboards: {len(models_used)}")
    for m in models_used:
        print(f"  - {m}")
    json.dump({"profiles": profiles, "coverage": cov, "chart_types": all_types,
               "usage_available": bool(usage), "usage_note": usage_note, "total_views": total_views},
              open(os.path.expanduser("~/thoughtspot-migration/assessment.json"), "w"), indent=2)
    print("\nFull report -> ~/thoughtspot-migration/assessment.json")

if __name__ == "__main__":
    main()
