import datetime
import random
import time
from typing import List, Optional

from fastapi import FastAPI, Query
from pydantic import BaseModel

from database import ensure_indexes, get_metrics_collection

app = FastAPI(title="Cloud Collector Service")


@app.on_event("startup")
def startup():
    try:
        ensure_indexes()
    except Exception:
        pass


class ResourceRef(BaseModel):
    resource_id: int | str
    company: Optional[str] = None
    project: Optional[str] = None
    provider: Optional[str] = None
    region: Optional[str] = None


class CollectRequest(BaseModel):
    client_id: str
    resources: List[ResourceRef]


METRIC_PROFILES = [
    ("cpu_usage",     "percent", 0.0,  100.0),
    ("memory_usage",  "percent", 5.0,  95.0),
    ("network_io",    "mbps",    0.0,  500.0),
    ("disk_io",       "mbps",    0.0,  300.0),
]

PROVIDER_DEFAULT = "aws"
REGION_DEFAULT = "us-east-1"


def _serialize(doc):
    doc["_id"] = str(doc["_id"])
    if isinstance(doc.get("timestamp"), datetime.datetime):
        doc["timestamp"] = doc["timestamp"].isoformat()
    return doc


@app.get("/health")
def health():
    return {"status": "ok", "service": "collector-service", "db": "mongodb"}


@app.post("/collect")
def collect(req: CollectRequest):
    start = time.time()
    col = get_metrics_collection()
    now = datetime.datetime.now(datetime.timezone.utc)

    docs = []
    for r in req.resources:
        for name, unit, lo, hi in METRIC_PROFILES:
            docs.append({
                "client_id": req.client_id,
                "resource_id": str(r.resource_id),
                "metric_name": name,
                "timestamp": now,
                "value": round(random.uniform(lo, hi), 2),
                "unit": unit,
                "provider": (r.provider or PROVIDER_DEFAULT).lower(),
                "region": r.region or REGION_DEFAULT,
            })

    inserted = 0
    if docs:
        result = col.insert_many(docs, ordered=False)
        inserted = len(result.inserted_ids)

    elapsed = (time.time() - start) * 1000
    return {
        "status": "ok",
        "client_id": req.client_id,
        "resources_observed": len(req.resources),
        "total_metrics": inserted,
        "metric_types": [m[0] for m in METRIC_PROFILES],
        "query_ms": round(elapsed, 2),
    }


@app.get("/metrics")
def get_metrics(
    client_id: str = Query(...),
    resource_id: Optional[str] = Query(None),
    metric_name: Optional[str] = Query(None),
    limit: int = Query(100, ge=1, le=1000),
):
    start = time.time()
    q = {"client_id": client_id}
    if resource_id:
        q["resource_id"] = resource_id
    if metric_name:
        q["metric_name"] = metric_name
    col = get_metrics_collection()
    docs = list(col.find(q).sort("timestamp", -1).limit(limit))
    elapsed = (time.time() - start) * 1000
    return {
        "total": len(docs),
        "filters": {k: v for k, v in q.items()},
        "metrics": [_serialize(d) for d in docs],
        "query_ms": round(elapsed, 2),
    }
