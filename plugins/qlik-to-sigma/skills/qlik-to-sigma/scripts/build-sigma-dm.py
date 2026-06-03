#!/usr/bin/env python3
import json, os, sys, urllib.request, secrets, string

BASE=os.environ["SIGMA_BASE_URL"]; TOK=os.environ["SIGMA_API_TOKEN"]
CONN=os.environ.get("SIGMA_CONNECTION_ID","")  # set to YOUR Sigma warehouse connection id (Sigma UI -> Connections)
if not CONN: sys.exit("set SIGMA_CONNECTION_ID to your Sigma warehouse connection id")
def api(method, path, body=None):
    data=json.dumps(body).encode() if body is not None else None
    req=urllib.request.Request(BASE+path, data=data, method=method,
        headers={"Authorization":"Bearer "+TOK,"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req) as r: return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        print("HTTP",e.code,"on",method,path,"->",e.read().decode()[:800], file=sys.stderr); raise

def disp(c): return " ".join(w.capitalize() for w in c.split("_"))
def nid(n=10): return "".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(n))

# real warehouse columns (curated)
T={
 "ORDER_FACT":["ORDER_ID","ORDER_LINE","CUSTOMER_KEY","PRODUCT_KEY","PROMO_KEY","ORDER_STORE_KEY","ORDER_DATE_KEY","ORDER_CHANNEL","ORDER_STATUS","SHIP_METHOD","QUANTITY_ORDERED","QUANTITY_RETURNED","UNIT_PRICE","UNIT_COST","DISCOUNT_AMOUNT","SHIPPING_AMOUNT","TAX_AMOUNT","GROSS_REVENUE","NET_REVENUE","GROSS_PROFIT","NET_PROFIT","DAYS_TO_SHIP"],
 "CUSTOMER_DIM":["CUSTOMER_KEY","CUSTOMER_ID","FIRST_NAME","LAST_NAME","REGION","CUSTOMER_SEGMENT","LOYALTY_TIER","ACQUISITION_CHANNEL"],
 "PRODUCT_DIM":["PRODUCT_KEY","PRODUCT_ID","PRODUCT_NAME","CATEGORY","SUBCATEGORY","BRAND"],
 "STORE_DIM":["STORE_KEY","STORE_ID","STORE_NAME","STORE_TYPE","REGION","DISTRICT","MANAGER_NAME"],
 "DATE_DIM":["DATE_KEY","FULL_DATE","MONTH_NUMBER","MONTH_NAME","QUARTER","YEAR","IS_HOLIDAY"],
 "PROMO_DIM":["PROMO_KEY","PROMO_NAME","PROMO_TYPE","CHANNEL","TARGET_SEGMENT"],
}
elemId={}; colId={}   # colId[(table,col)] = id
elements=[]
for tbl,cols in T.items():
    eid=nid(); elemId[tbl]=eid
    ecols=[]; order=[]
    for c in cols:
        cid=nid(); colId[(tbl,c)]=cid
        ecols.append({"id":cid,"formula":"[%s/%s]"%(tbl,disp(c))}); order.append(cid)
    elements.append({"id":eid,"kind":"table",
        "source":{"connectionId":CONN,"kind":"warehouse-table","path":["CSA","TJ",tbl]},
        "columns":ecols,"order":order})

# metrics on ORDER_FACT (Sigma-correct formulas; bracketed display names)
metrics=[
 ("Net Revenue","Sum([Net Revenue])","$,.2f"),("Gross Revenue","Sum([Gross Revenue])","$,.2f"),
 ("Net Profit","Sum([Net Profit])","$,.2f"),("Gross Profit","Sum([Gross Profit])","$,.2f"),
 ("Units Sold","Sum([Quantity Ordered])",None),("Units Returned","Sum([Quantity Returned])",None),
 ("Order Count","CountDistinct([Order Id])",",.0f"),
 ("Avg Order Value","Sum([Net Revenue])/CountDistinct([Order Id])","$,.2f"),
 ("Net Margin %","Sum([Net Profit])/Sum([Net Revenue])",",.1%"),
 ("Return Rate %","Sum([Quantity Returned])/Sum([Quantity Ordered])",",.1%"),
 ("Avg Days to Ship","Avg([Days to Ship])",",.1f"),("Discount Amount","Sum([Discount Amount])","$,.2f"),
]
of=[e for e in elements if e["id"]==elemId["ORDER_FACT"]][0]
of["metrics"]=[]
for name,f,fmt in metrics:
    m={"id":nid(),"formula":f,"name":name}
    if fmt: m["format"]={"kind":"number","formatString":fmt}
    of["metrics"].append(m)

# relationships: each dim -> ORDER_FACT
REL=[("CUSTOMER_DIM","CUSTOMER_KEY","CUSTOMER_KEY"),("PRODUCT_DIM","PRODUCT_KEY","PRODUCT_KEY"),
     ("PROMO_DIM","PROMO_KEY","PROMO_KEY"),("STORE_DIM","STORE_KEY","ORDER_STORE_KEY"),
     ("DATE_DIM","DATE_KEY","ORDER_DATE_KEY")]
for dim,dk,fk in REL:
    el=[e for e in elements if e["id"]==elemId[dim]][0]
    el.setdefault("relationships",[]).append({"id":nid(),"targetElementId":elemId["ORDER_FACT"],
        "keys":[{"sourceColumnId":colId[(dim,dk)],"targetColumnId":colId[("ORDER_FACT",fk)]}],
        "name":"ORDER_FACT"})

# denormalized reporting element (SQL join) — bulletproof master for workbook charts
DENORM_SQL = """SELECT
 f.ORDER_ID, f.NET_REVENUE, f.GROSS_REVENUE, f.NET_PROFIT, f.GROSS_PROFIT,
 f.QUANTITY_ORDERED, f.QUANTITY_RETURNED, f.DISCOUNT_AMOUNT, f.DAYS_TO_SHIP,
 f.ORDER_CHANNEL, f.ORDER_STATUS,
 p.CATEGORY, p.SUBCATEGORY, p.BRAND,
 c.REGION AS CUSTOMER_REGION, c.CUSTOMER_SEGMENT, c.LOYALTY_TIER,
 s.STORE_NAME, s.REGION AS STORE_REGION, s.DISTRICT,
 d.MONTH_NUMBER, d.MONTH_NAME, d.QUARTER, d.YEAR, d.IS_HOLIDAY,
 pr.PROMO_TYPE
FROM CSA.TJ.ORDER_FACT f
LEFT JOIN CSA.TJ.PRODUCT_DIM  p  ON f.PRODUCT_KEY = p.PRODUCT_KEY
LEFT JOIN CSA.TJ.CUSTOMER_DIM c  ON f.CUSTOMER_KEY = c.CUSTOMER_KEY
LEFT JOIN CSA.TJ.STORE_DIM    s  ON f.ORDER_STORE_KEY = s.STORE_KEY
LEFT JOIN CSA.TJ.DATE_DIM     d  ON f.ORDER_DATE_KEY = d.DATE_KEY
LEFT JOIN CSA.TJ.PROMO_DIM    pr ON f.PROMO_KEY = pr.PROMO_KEY"""
DENORM_COLS=["ORDER_ID","NET_REVENUE","GROSS_REVENUE","NET_PROFIT","GROSS_PROFIT","QUANTITY_ORDERED","QUANTITY_RETURNED","DISCOUNT_AMOUNT","DAYS_TO_SHIP","ORDER_CHANNEL","ORDER_STATUS","CATEGORY","SUBCATEGORY","BRAND","CUSTOMER_REGION","CUSTOMER_SEGMENT","LOYALTY_TIER","STORE_NAME","STORE_REGION","DISTRICT","MONTH_NUMBER","MONTH_NAME","QUARTER","YEAR","IS_HOLIDAY","PROMO_TYPE"]
denorm_id=nid()
dcols=[]; dorder=[]
for c in DENORM_COLS:
    cid=nid(); dcols.append({"id":cid,"name":disp(c),"formula":"[Custom SQL/%s]"%c}); dorder.append(cid)
elements.append({"id":denorm_id,"kind":"table",
    "source":{"connectionId":CONN,"kind":"sql","statement":DENORM_SQL},
    "columns":dcols,"order":dorder})

spec={"name":"Retail Orders (Qlik→Sigma)","schemaVersion":1,
      "pages":[{"id":nid(),"name":"Page 1","elements":elements}]}

# resolve a folder to drop it in (prefer a writable workspace folder)
folder=None
files=api("GET","/v2/files?typeFilters=folder&limit=200")
for f in files.get("entries",files.get("data",[])):
    if f.get("type")=="folder" and (f.get("permission") in ("edit","explore",None) or True):
        folder=f["id"]
        if "TEST" in (f.get("name","").upper()) or "MIGRATION" in (f.get("name","").upper()): break
print("folder:",folder, file=sys.stderr)
body=dict(spec);
if folder: body["folderId"]=folder
res=api("POST","/v2/dataModels/spec",body)
print(json.dumps({"dataModelId":res.get("dataModelId") or res.get("id"),"name":res.get("name"),
    "elemId":elemId,"keys":{k[0]+"."+k[1]:v for k,v in colId.items() if k[1].endswith("KEY")}}, indent=2))
