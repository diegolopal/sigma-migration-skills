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
        "columns":[{"id":c,"formula":formula,"name":name,"format":NUM(fmt)}],"value":{"id":c}}
def chart(kind,name,dimf,dimn,measures):
    x=nid()+"-x"; cols=[{"id":x,"formula":dimf,"name":dimn}]; ymids=[]
    for mf,mn,fmt in measures:
        y=nid()+"-y"; cols.append({"id":y,"formula":mf,"name":mn,"format":NUM(fmt)}); ymids.append(y)
    return {"id":nid(),"kind":kind,"name":name,"source":{"elementId":"m-ofv","kind":"table"},
        "columns":cols,"xAxis":{"columnId":x},"yAxis":{"columnIds":ymids}}
def table(name,dims,measures):
    cols=[]; 
    for f,n in dims: cols.append({"id":nid(),"formula":f,"name":n})
    for f,n,fmt in measures: cols.append({"id":nid(),"formula":f,"name":n,"format":NUM(fmt)})
    return {"id":nid(),"kind":"table","name":name,"source":{"elementId":"m-ofv","kind":"table"},"columns":cols}

overview=[
 kpi("Net Revenue","Sum([OFV/Net Revenue])","$,.0f"),
 kpi("Orders","CountDistinct([OFV/Order Id])",",.0f"),
 kpi("Net Margin","Sum([OFV/Net Profit]) / Sum([OFV/Net Revenue])",",.1%"),
 chart("bar-chart","Net Revenue by Category","[OFV/Category]","Category",[("Sum([OFV/Net Revenue])","Net Revenue","$,.0f")]),
 chart("line-chart","Revenue & Profit by Month","[OFV/Month Number]","Month",
       [("Sum([OFV/Net Revenue])","Net Revenue","$,.0f"),("Sum([OFV/Net Profit])","Net Profit","$,.0f")]),
 chart("bar-chart","Net Revenue by Customer Segment","[OFV/Customer Segment]","Segment",[("Sum([OFV/Net Revenue])","Net Revenue","$,.0f")]),
 table("Store Performance",[("[OFV/Store Name]","Store"),("[OFV/Store Region]","Region")],
       [("Sum([OFV/Net Revenue])","Net Revenue","$,.0f"),("CountDistinct([OFV/Order Id])","Orders",",.0f")]),
]
spec={"name":"Retail Orders — Overview (from Qlik)","folderId":FOLDER,"schemaVersion":1,
  "pages":[{"id":"page-data","name":"Data","elements":[master]},
           {"id":"page-overview","name":"Overview","elements":overview}]}
res=post("/v2/workbooks/spec",spec)
import re
m=re.search(r'workbookId:\s*(\S+)',res)
print("workbookId:", m.group(1) if m else res[:200])
print("element ids:", json.dumps({e["name"]:e["id"] for e in overview}))
