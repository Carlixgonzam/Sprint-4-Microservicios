import time
from typing import Any, List, Optional

from fastapi import Depends, FastAPI, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import desc
from sqlalchemy.orm import Session

import database
import models

# Tables are created by setup-databases.sh; this is a safety net for fresh installs.
models.Base.metadata.create_all(bind=database.engine)

app = FastAPI(title="Cost Analyzer Service")


class ResourceIn(BaseModel):
    id: Optional[Any] = None
    company: Optional[str] = None
    project: Optional[str] = None
    provider: Optional[str] = None
    resource_type: Optional[str] = None
    status: Optional[str] = None
    cpu_usage: Optional[float] = 0.0
    monthly_cost: Optional[float] = 0.0
    underutilized: Optional[bool] = False


class MetricsSummary(BaseModel):
    total_metrics: Optional[int] = 0
    resources_observed: Optional[int] = 0


class AnalyzeRequest(BaseModel):
    client_id: str
    company: Optional[str] = None
    resources: List[ResourceIn] = []
    metrics_summary: Optional[MetricsSummary] = None


CPU_LOW_THRESHOLD = 10.0
STOPPED_STATES = {"stopped", "terminated"}


def _apply_rules(resources: List[ResourceIn]) -> List[dict]:
    """Return list of recommendation dicts; mirrors context.md optimization rules."""
    recs: List[dict] = []
    for r in resources:
        rid = str(r.id) if r.id is not None else "unknown"
        cost = float(r.monthly_cost or 0.0)
        cpu = float(r.cpu_usage or 0.0)
        status = (r.status or "").lower()

        if status in STOPPED_STATES and cost > 0:
            recs.append({
                "resource_id": rid,
                "recommendation_type": "terminate",
                "description": (f"Resource {rid} ({r.resource_type or 'n/a'}) is in "
                                f"state '{status}' but still incurs ${cost:.2f}/month. "
                                f"Consider termination."),
                "estimated_savings": round(cost, 2),
                "priority": "high",
            })
        elif cpu < CPU_LOW_THRESHOLD and cost > 0:
            saving = round(cost * 0.5, 2)
            recs.append({
                "resource_id": rid,
                "recommendation_type": "downsize",
                "description": (f"Resource {rid} ({r.resource_type or 'n/a'}) shows "
                                f"{cpu:.1f}% CPU usage. Downsizing could save ~50%."),
                "estimated_savings": saving,
                "priority": "medium",
            })
        elif cost > 200:
            saving = round(cost * 0.2, 2)
            recs.append({
                "resource_id": rid,
                "recommendation_type": "reserved_instance",
                "description": (f"Resource {rid} costs ${cost:.2f}/month. "
                                f"Reserved instances could save ~20%."),
                "estimated_savings": saving,
                "priority": "low",
            })
    return recs


def _serialize_analysis(a: models.CostAnalysis, recs: Optional[List[models.Recommendation]] = None) -> dict:
    out = {
        "id": str(a.id),
        "client_id": a.client_id,
        "company": a.company,
        "total_cost": float(a.total_cost or 0),
        "total_cost_optimized": float(a.total_cost_optimized or 0),
        "savings_potential": float(a.savings_potential or 0),
        "recommendations_count": int(a.recommendations_count or 0),
        "created_at": a.created_at.isoformat() if a.created_at else None,
        "analysis_data": a.analysis_data or {},
    }
    if recs is not None:
        out["recommendations"] = [_serialize_rec(r) for r in recs]
    return out


def _serialize_rec(r: models.Recommendation) -> dict:
    return {
        "id": str(r.id),
        "resource_id": r.resource_id,
        "recommendation_type": r.recommendation_type,
        "description": r.description,
        "estimated_savings": float(r.estimated_savings or 0),
        "priority": r.priority,
        "status": r.status,
    }


@app.get("/health")
def health():
    return {"status": "ok", "service": "analyzer-service", "db": "postgresql"}


@app.post("/analyze")
def analyze(req: AnalyzeRequest, db: Session = Depends(database.get_db)):
    start = time.time()

    total_cost = sum(float(r.monthly_cost or 0.0) for r in req.resources)
    rec_dicts = _apply_rules(req.resources)
    total_savings = sum(r["estimated_savings"] for r in rec_dicts)
    total_optimized = max(total_cost - total_savings, 0.0)

    analysis = models.CostAnalysis(
        client_id=req.client_id,
        company=req.company,
        total_cost=round(total_cost, 2),
        total_cost_optimized=round(total_optimized, 2),
        savings_potential=round(total_savings, 2),
        recommendations_count=len(rec_dicts),
        analysis_data={
            "resources_analyzed": len(req.resources),
            "metrics_observed": (req.metrics_summary.total_metrics
                                 if req.metrics_summary else 0),
        },
    )
    db.add(analysis)
    db.flush()

    rec_models = [
        models.Recommendation(cost_analysis_id=analysis.id, **rec)
        for rec in rec_dicts
    ]
    db.add_all(rec_models)
    db.commit()
    db.refresh(analysis)

    elapsed = (time.time() - start) * 1000
    return {
        **_serialize_analysis(analysis, rec_models),
        "query_ms": round(elapsed, 2),
    }


@app.get("/analysis/{analysis_id}")
def get_analysis(analysis_id: str, db: Session = Depends(database.get_db)):
    a = db.query(models.CostAnalysis).filter(models.CostAnalysis.id == analysis_id).first()
    if not a:
        raise HTTPException(status_code=404, detail={"error": "analysis not found"})
    recs = (db.query(models.Recommendation)
              .filter(models.Recommendation.cost_analysis_id == a.id)
              .all())
    return _serialize_analysis(a, recs)


@app.get("/recommendations")
def list_recommendations(
    client_id: str = Query(...),
    limit: int = Query(50, ge=1, le=500),
    db: Session = Depends(database.get_db),
):
    q = (db.query(models.Recommendation, models.CostAnalysis)
           .join(models.CostAnalysis, models.Recommendation.cost_analysis_id == models.CostAnalysis.id)
           .filter(models.CostAnalysis.client_id == client_id)
           .order_by(desc(models.Recommendation.created_at))
           .limit(limit))
    rows = q.all()
    return {
        "client_id": client_id,
        "total": len(rows),
        "recommendations": [
            {**_serialize_rec(r), "cost_analysis_id": str(a.id),
             "company": a.company, "created_at": r.created_at.isoformat() if r.created_at else None}
            for r, a in rows
        ],
    }
