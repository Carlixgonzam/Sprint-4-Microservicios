import logging
import time
import uuid
from contextlib import asynccontextmanager
from threading import Thread
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import worker
from broker import ReportQueue
from cache import ReportCache

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("orchestrator")

REPORT_TTL = {
    "monthly": 24 * 3600,
    "weekly":  12 * 3600,
    "daily":    4 * 3600,
}

cache = ReportCache()
queue = ReportQueue()


@asynccontextmanager
async def lifespan(app: FastAPI):
    t = Thread(target=worker.run, args=(cache,), daemon=True)
    t.start()
    logger.info("Background worker started")
    yield


app = FastAPI(title="Orchestrator Service", lifespan=lifespan)


class ReportRequest(BaseModel):
    client_id: str
    report_type: str = "monthly_analysis"
    period: str = "monthly"
    company: Optional[str] = None
    include_recommendations: bool = True


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "orchestrator-service",
        "redis": cache.ping(),
        "rabbitmq": queue.ping(),
    }


@app.post("/reports/generate")
def generate_report(req: ReportRequest):
    composite_key = f"report:{req.client_id}:{req.report_type}:{req.period}"
    cached = cache.get(composite_key)
    if cached:
        return {
            "cached": True,
            "report_id": cached.get("report_id"),
            "status": "ready",
            "data": cached,
        }

    report_id = str(uuid.uuid4())
    msg = {
        "message_id": str(uuid.uuid4()),
        "report_id": report_id,
        "client_id": req.client_id,
        "request_type": "generate_report",
        "timestamp": time.time(),
        "data": {
            "report_type": req.report_type,
            "period": req.period,
            "company": req.company,
            "include_recommendations": req.include_recommendations,
        },
        "ttl": REPORT_TTL.get(req.period, 3600),
        "retry_count": 0,
        "max_retries": 3,
    }
    queue.publish(msg)
    cache.set(f"report:status:{report_id}", {"status": "processing", "queued_at": time.time()}, ttl=3600)

    return {
        "cached": False,
        "report_id": report_id,
        "status": "queued",
        "message": "Report generation enqueued. Poll GET /reports/{report_id} for status.",
    }


@app.get("/reports/{report_id}")
def get_report(report_id: str):
    status = cache.get(f"report:status:{report_id}")
    if status and status.get("status") == "processing":
        return {"report_id": report_id, "status": "processing"}

    result = cache.get(f"report:id:{report_id}")
    if result:
        return result

    raise HTTPException(status_code=404, detail={"error": "report not found or expired"})
