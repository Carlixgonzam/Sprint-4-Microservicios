import time
from fastapi import FastAPI, Depends, Query
from sqlalchemy.orm import Session
from sqlalchemy import text
import models, database

models.Base.metadata.create_all(bind=database.engine)

app = FastAPI(title="Inventory Service")

@app.get("/health")
def health():
    return {"status": "ok", "service": "inventory-service", "db": "postgresql"}

@app.get("/resources")
def get_resources(
    company: str = Query(None),
    project: str = Query(None),
    db: Session = Depends(database.get_db)
):
    start = time.time()
    q = db.query(models.CloudResource)
    if company:
        q = q.filter(models.CloudResource.company == company)
    if project:
        q = q.filter(models.CloudResource.project == project)
    resources = q.all()
    underutilized = [r for r in resources if r.cpu_usage < 10.0]
    elapsed = (time.time() - start) * 1000
    return {
        "total": len(resources),
        "underutilized_count": len(underutilized),
        "resources": [
            {
                "id": r.id,
                "company": r.company,
                "project": r.project,
                "provider": r.provider,
                "resource_type": r.resource_type,
                "status": r.status,
                "cpu_usage": r.cpu_usage,
                "monthly_cost": r.monthly_cost,
                "underutilized": r.cpu_usage < 10.0
            } for r in resources
        ],
        "query_ms": round(elapsed, 2)
    }

@app.get("/resources/summary")
def get_summary(db: Session = Depends(database.get_db)):
    result = db.execute(text("""
        SELECT company, project, provider,
               COUNT(*) as total_resources,
               SUM(monthly_cost) as total_cost,
               AVG(cpu_usage) as avg_cpu,
               SUM(CASE WHEN cpu_usage < 10 THEN 1 ELSE 0 END) as underutilized
        FROM cloud_resources
        GROUP BY company, project, provider
        ORDER BY total_cost DESC
    """)).fetchall()
    return {
        "summary": [dict(r._mapping) for r in result]
    }
