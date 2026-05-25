import time
from fastapi import FastAPI, Query
from database import get_costs_collection, get_monthly_collection
from bson import ObjectId

app = FastAPI(title="Report Service")

def serialize(doc):
    doc["_id"] = str(doc["_id"])
    return doc

@app.get("/health")
def health():
    return {"status": "ok", "service": "report-service", "db": "mongodb"}

@app.get("/costs")
def get_costs(
    company: str = Query(None),
    project: str = Query(None),
    month: str = Query(None)
):
    start = time.time()
    col = get_costs_collection()
    query = {}
    if company: query["company"] = company
    if project: query["project"] = project
    if month: query["month"] = month
    docs = list(col.find(query).limit(200))
    total_cost = sum(d.get("total_cost", 0) for d in docs)
    waste_cost = sum(d.get("waste_cost", 0) for d in docs)
    elapsed = (time.time() - start) * 1000
    return {
        "total_reports": len(docs),
        "total_cost_usd": round(total_cost, 2),
        "waste_cost_usd": round(waste_cost, 2),
        "waste_pct": round((waste_cost / total_cost * 100) if total_cost else 0, 1),
        "reports": [serialize(d) for d in docs],
        "query_ms": round(elapsed, 2)
    }

@app.get("/costs/monthly/{company}")
def get_monthly(company: str):
    start = time.time()
    col = get_monthly_collection()
    docs = list(col.find({"company": company}).sort("month", -1).limit(12))
    elapsed = (time.time() - start) * 1000
    return {
        "company": company,
        "months": [serialize(d) for d in docs],
        "query_ms": round(elapsed, 2)
    }
