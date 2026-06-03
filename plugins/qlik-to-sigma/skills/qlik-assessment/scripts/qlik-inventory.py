#!/usr/bin/env python3
"""qlik-inventory — Qlik Cloud tenant inventory + per-app migration complexity.

    python3 qlik-inventory.py [--context <ctx>] [--out assessment] [--deep]

Enumerates apps (+ usage/reload/flags), spaces, users. With --deep, opens each app
to bucket master-measure expressions and chart viz types against Sigma coverage
(reuses the MeasureList enumeration from qlik-to-sigma/qlik-discover.py), then scores
value/(1+cost) and tags each app. Emits <out>/inventory.json + <out>/readout.md.

Uses the active qlik-cli context. Read-only except --deep (briefly creates+removes a
temporary MeasureList object per app to enumerate master measures).
"""
import json, os, re, subprocess, sys, argparse, math, tempfile, secrets, string

def q(*a, raw=False):
    o = subprocess.run(["qlik", *a], capture_output=True, text=True)
    if raw: return o.stdout
    try: return json.loads(o.stdout or "null")
    except json.JSONDecodeError: return None

# expression buckets (mirror convert_qlik_to_sigma's qlikExprToSigma)
UNHANDLED = re.compile(r'\b(Aggr|Dual|Get(Field)?(Selections?|CurrentSelections?|PossibleCount|SelectedCount|AlternativeCount|ExcludedCount)|Range(Sum|Avg|Min|Max|Count|Stdev|Mode|Skew|Kurtosis|Correl|Fractile))\s*\(', re.I)
MANUAL = re.compile(r'\{\s*[\$1<][^}]*[}>]|\bClass\s*\(', re.I)  # set analysis or binning
def bucket_expr(e):
    if not e: return "auto"
    if UNHANDLED.search(e): return "unhandled"
    if MANUAL.search(e):    return "manual"
    return "auto"
VIZ_AUTO={"barchart","linechart","combochart","piechart","kpi","table","pivot-table","scatterplot","gauge","text"}
VIZ_MANUAL={"mekko","funnel","sankey","map","boxplot","waterfall","distributionplot","bulletchart","histogram"}
def bucket_viz(t):
    t=(t or "").lower()
    if t in VIZ_AUTO: return "auto"
    if t in VIZ_MANUAL: return "manual"
    if t=="sheet": return None
    return "unhandled"   # extensions / custom viz

def enum_measures(app, ctx):
    oid="inv-"+"".join(secrets.choice(string.ascii_lowercase) for _ in range(8))
    props={"qInfo":{"qId":oid,"qType":"MeasureList"},"qMeasureListDef":{"qType":"measure",
        "qData":{"title":"/qMetaDef/title","expr":"/qMeasure/qDef"}}}
    f=tempfile.NamedTemporaryFile("w",suffix=".json",delete=False); json.dump(props,f); f.close()
    subprocess.run(["qlik","app","object","set",f.name,"-a",app,*ctx],capture_output=True,text=True)
    lay=q("app","object","layout",oid,"-a",app,*ctx)
    subprocess.run(["qlik","app","object","rm",oid,"-a",app,*ctx],capture_output=True,text=True)
    os.unlink(f.name)
    items=((lay or {}).get("qMeasureList") or {}).get("qItems",[])
    return [it.get("qData",{}).get("expr","") for it in items]

def score(views, n_auto, n_hint, n_manual, n_unhandled, charts, measures):
    cost = 10*n_unhandled + 3*n_manual + 1*n_hint
    value = (views * math.sqrt(max(views,1))) if views else 10*(charts + measures/4)
    return cost, round(value/(1+cost),2)
def tag(views, sc, n_manual, n_unhandled):
    if views==0: return "retire"
    if n_unhandled>=1: return "needs-gap-scout"
    if sc>=20 and (n_manual+n_unhandled)==0: return "migrate-first"
    if sc>=10: return "easy-win"
    return "moderate"

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--context"); ap.add_argument("--out",default="assessment"); ap.add_argument("--deep",action="store_true")
    a=ap.parse_args(); ctx=["--context",a.context] if a.context else []; os.makedirs(a.out,exist_ok=True)

    apps=q("item","ls","--resourceType","app","--limit","200","--json",*ctx) or []
    spaces=q("space","ls","--limit","200","--json",*ctx) or []
    rows=[]
    for it in apps:
        ra=it.get("resourceAttributes",{})
        row={"id":it.get("resourceId"),"name":it.get("name"),"space":it.get("spaceId"),
             "views":(it.get("itemViews") or {}).get("trendCurrent",0) if isinstance(it.get("itemViews"),dict) else (it.get("itemViews") or 0),
             "reloadStatus":it.get("resourceReloadStatus"),"lastReload":ra.get("lastReloadTime"),
             "sectionAccess":bool(ra.get("hasSectionAccess")),"directQuery":bool(ra.get("isDirectQueryMode")),
             "n_auto":0,"n_hint":0,"n_manual":0,"n_unhandled":0,"measure_buckets":{},"viz_types":{}}
        if a.deep and row["id"]:
            exprs=enum_measures(row["id"],ctx)
            mb={"auto":0,"manual":0,"unhandled":0}
            for e in exprs: mb[bucket_expr(e)]+=1
            objs=q("app","object","ls","-a",row["id"],"--json",*ctx) or []
            charts=0
            for o in objs:
                b=bucket_viz(o.get("qType"))
                if b is None: continue
                charts+=1; row["viz_types"][o.get("qType")]=row["viz_types"].get(o.get("qType"),0)+1
                row[{"auto":"n_auto","manual":"n_manual","unhandled":"n_unhandled"}[b]]+=1
            row["n_auto"]+=mb["auto"]; row["n_manual"]+=mb["manual"]+(1 if row["sectionAccess"] else 0)+(1 if row["directQuery"] else 0); row["n_unhandled"]+=mb["unhandled"]
            row["measure_buckets"]=mb; row["_charts"]=charts; row["_measures"]=len(exprs)
        c,sc=score(row["views"],row["n_auto"],row["n_hint"],row["n_manual"],row["n_unhandled"],row.get("_charts",0),row.get("_measures",0))
        row["cost"],row["score"]=c,sc; row["tag"]=tag(row["views"],sc,row["n_manual"],row["n_unhandled"])
        rows.append(row)
    rows.sort(key=lambda r:r["score"],reverse=True)
    inv={"tenant":os.environ.get("QLIK_TENANT","(active context)"),"apps":len(apps),"spaces":len(spaces),"shortlist":rows}
    json.dump(inv,open(os.path.join(a.out,"inventory.json"),"w"),indent=2)

    md=[f"# Qlik → Sigma assessment\n",f"- **Apps:** {len(apps)}  · **Spaces:** {len(spaces)}\n","\n## Migration shortlist\n",
        "| App | Space | Views | Tag | Score | auto/manual/unhandled | Flags |","|---|---|--:|---|--:|---|---|"]
    for r in rows:
        flags=",".join([f for f,v in [("SectionAccess",r["sectionAccess"]),("DirectQuery",r["directQuery"])] if v]) or "—"
        md.append(f"| {r['name']} | … | {r['views']} | **{r['tag']}** | {r['score']} | {r['n_auto']}/{r['n_manual']}/{r['n_unhandled']} | {flags} |")
    open(os.path.join(a.out,"readout.md"),"w").write("\n".join(md)+"\n")
    print(f"apps={len(apps)} spaces={len(spaces)} -> {a.out}/inventory.json + readout.md"+("" if a.deep else "  (run with --deep for per-app complexity)"))

if __name__=="__main__": main()
