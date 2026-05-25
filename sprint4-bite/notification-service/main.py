import asyncio
import time
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel

app = FastAPI(title="Notification Service")

class JobRequest(BaseModel):
    job_id: str
    email: str
    company: str
    project: str

jobs = {}

async def process_job(job_id: str, email: str, company: str, project: str):
    await asyncio.sleep(3)
    jobs[job_id] = {
        "status": "done",
        "email": email,
        "company": company,
        "project": project,
        "completed_at": time.time(),
        "message": f"Analysis for {company}/{project} completed. Results sent to {email}."
    }
    print(f"[NOTIF] Job {job_id} done → email enviado a {email}")

@app.get("/health")
def health():
    return {"status": "ok", "service": "notification-service"}

@app.post("/jobs")
async def create_job(req: JobRequest, background_tasks: BackgroundTasks):
    jobs[req.job_id] = {"status": "processing", "email": req.email}
    background_tasks.add_task(
        process_job, req.job_id, req.email, req.company, req.project
    )
    return {"job_id": req.job_id, "status": "queued", "message": "Analysis running in background"}

@app.get("/jobs/{job_id}")
def get_job(job_id: str):
    return jobs.get(job_id, {"error": "job not found"})
