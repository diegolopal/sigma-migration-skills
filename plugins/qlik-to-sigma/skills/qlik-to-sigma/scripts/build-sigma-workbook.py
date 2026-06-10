#!/usr/bin/env python3
import json, os, sys, urllib.request, secrets, string
BASE=os.environ["SIGMA_BASE_URL"]; TOK=os.environ["SIGMA_API_TOKEN"]
# Set these to YOUR ids: the data model + denormalized element from build-sigma-dm.py, and the target folder.
DM=os.environ.get("SIGMA_DM_ID",""); DENORM=os.environ.get("SIGMA_DENORM_ELEMENT_ID","")
FOLDER=os.environ.get("SIGMA_FOLDER_ID","")
if not (DM and DENORM and FOLDER): sys.exit("set SIGMA_DM_ID / SIGMA_DENORM_ELEMENT_ID / SIGMA_FOLDER_ID")
def post(path,body):
    r=urllib.request.Request(BASE+path,data=json.dumps(body).encode(),method="POST",
        headers={"Authorization":"Bearer "+TOK,"Content-Type":"application/json"})
    try: return urllib.request.urlopen(r).read().decode()
    except urllib.error.HTTPError as e: print("HTTP",e.code,e.read().decode()[:500],file=sys.stderr); raise
def nid(): return "el-"+"".join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range(8))
NUM=lambda fs:{"kind":"number","formatString":fs}

# master table OFV (denormalized element) — surface the columns this dashboard needs
MCOLS=["Net Revenue","Net Profit","Order Id","Category","Customer Segment","Store Name","Store Region","Month Number","Month Name"]
master={"id":"m-ofv","name":"OFV","kind":"table","source":{"dataModelId":DM,"elementId":DENORM,"kind":"data-model"},
        "columns":[{"id":"ofv-%d"%i,"formula":"[Custom SQL/%s]"%c,"name":c} for i,c in enumerate(MCOLS)]}

def kpi(name,formula,fmt):
    c=nid()+"-v"; return {"id":nid(),"kind":"kpi-chart","name":name,"source":{"elementId":"m-ofv","kind":"table"},
        "columns":[{"id":c,"formula":formula,"name":name,"format":NUM(fmt)}],"value":{"columnId":c}}
# Qlik's associative model hides unmatched/null dimension keys (a LEFT-JOIN miss never
# shows as a row in a Qlik straight table). Sigma keeps those rows, so a faithful
# migration excludes them on the TABLE element (NOT on the master — an element filter on
# a shared SOURCE element propagates into every chart that sources it). Deliberate
# choice: set QLIK_KEEP_UNMATCHED=1 to keep the null rows instead (warehouse-faithful).
KEEP_UNMATCHED=os.environ.get("QLIK_KEEP_UNMATCHED","")=="1"

def chart(kind,name,dimf,dimn,measures,sort=None):
    """sort: optional ("<measure or dim display name>", "ascending"|"descending") carried
    from the Qlik object definition (qDimensionInfo qSortCriterias / measure qSortBy in
    the discover output's charts.json). None = Sigma default ordering."""
    x=nid()+"-x"; cols=[{"id":x,"formula":dimf,"name":dimn}]; ymids=[]; byname={dimn:x}
    for mf,mn,fmt in measures:
        y=nid()+"-y"; cols.append({"id":y,"formula":mf,"name":mn,"format":NUM(fmt)}); ymids.append(y); byname[mn]=y
    el={"id":nid(),"kind":kind,"name":name,"source":{"elementId":"m-ofv","kind":"table"},
        "columns":cols,"xAxis":{"columnId":x},"yAxis":{"columnIds":ymids}}
    if sort and sort[0] in byname:
        el["xAxis"]["sort"]={"by":byname[sort[0]],"direction":sort[1]}
    # value labels on bar/pie/donut (Sigma defaults them OFF); lines stay clean
    if kind in ("bar-chart","pie-chart","donut-chart"): el["dataLabel"]={"labels":"shown"}
    return el
def table(name,dims,measures,sort=None,exclude_null_dim=None):
    """A Qlik straight table is an AGGREGATING element: without a `groupings` array a
    Sigma table with dim + Sum(...) columns renders ONE ROW PER SOURCE ROW (refs/
    sigma-build-gotchas.md "Aggregating elements need an explicit dimension→measure
    declaration"). groupBy = the dim column ids, calculations = the measure column ids.

    sort: optional ("<col display name>", "ascending"|"descending") carried from the
      Qlik object definition where it provides one (qSortCriterias/qSortBy in the
      discover output). Verified shape (live POST+readback 2026-06-10): a GROUPED
      table rejects element-level `sort` ("Sort column not found") -- the sort must
      nest INSIDE the grouping entry: groupings[0].sort=[{columnId,direction}].
    exclude_null_dim: display name of a dim whose null/unmatched rows to drop (the
      associative-model behavior — see KEEP_UNMATCHED above). Emits a hidden boolean
      calc column + the gotchas-documented element list-filter
      filters:[{columnId, kind:"list", mode:"include", values:[true]}]."""
    cols=[]; gids=[]; cids=[]; byname={}; byform={}
    for f,n in dims:
        i=nid(); cols.append({"id":i,"formula":f,"name":n}); gids.append(i); byname[n]=i; byform[n]=f
    for f,n,fmt in measures:
        i=nid(); cols.append({"id":i,"formula":f,"name":n,"format":NUM(fmt)}); cids.append(i); byname[n]=i
    el={"id":nid(),"kind":"table","name":name,"source":{"elementId":"m-ofv","kind":"table"},
        "columns":cols,"groupings":[{"id":nid()+"-g","groupBy":gids,"calculations":cids}]}
    if sort and sort[0] in byname:
        el["groupings"][0]["sort"]=[{"columnId":byname[sort[0]],"direction":sort[1]}]
    if exclude_null_dim and not KEEP_UNMATCHED and exclude_null_dim in byform:
        b=nid()+"-nn"
        cols.append({"id":b,"formula":"Not(IsNull(%s))"%byform[exclude_null_dim],
                     "name":"%s Matched"%exclude_null_dim,"hidden":True})
        el["filters"]=[{"id":nid()+"-f","columnId":b,"kind":"list","mode":"include","values":[True]}]
    return el

overview=[
 kpi("Net Revenue","Sum([OFV/Net Revenue])","$,.0f"),
 kpi("Orders","CountDistinct([OFV/Order Id])",",.0f"),
 kpi("Net Margin","Sum([OFV/Net Profit]) / Sum([OFV/Net Revenue])",",.1%"),
 chart("bar-chart","Net Revenue by Category","[OFV/Category]","Category",[("Sum([OFV/Net Revenue])","Net Revenue","$,.0f")]),
 chart("line-chart","Revenue & Profit by Month","[OFV/Month Number]","Month",
       [("Sum([OFV/Net Revenue])","Net Revenue","$,.0f"),("Sum([OFV/Net Profit])","Net Profit","$,.0f")]),
 chart("bar-chart","Net Revenue by Customer Segment","[OFV/Customer Segment]","Segment",[("Sum([OFV/Net Revenue])","Net Revenue","$,.0f")]),
 # Qlik hides the unmatched-store rows (associative model) and the source table reads
 # best by revenue — group by the dims, sort desc, drop the null-store bucket.
 table("Store Performance",[("[OFV/Store Name]","Store"),("[OFV/Store Region]","Region")],
       [("Sum([OFV/Net Revenue])","Net Revenue","$,.0f"),("CountDistinct([OFV/Order Id])","Orders",",.0f")],
       sort=("Net Revenue","descending"),exclude_null_dim="Store"),
]
spec={"name":"Retail Orders — Overview (from Qlik)","folderId":FOLDER,"schemaVersion":1,
  "pages":[{"id":"page-data","name":"Data","elements":[master]},
           {"id":"page-overview","name":"Overview","elements":overview}]}
res=post("/v2/workbooks/spec",spec)
import re
m=re.search(r'workbookId:\s*(\S+)',res)
print("workbookId:", m.group(1) if m else res[:200])
print("element ids:", json.dumps({e["name"]:e["id"] for e in overview}))
