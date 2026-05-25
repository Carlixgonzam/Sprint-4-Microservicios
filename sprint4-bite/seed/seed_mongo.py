from pymongo import MongoClient
import random
from datetime import datetime

MONGO_URL = "mongodb://:27017"

client = MongoClient(MONGO_URL)
db = client["bite_reports"]

companies = ["Bancolombia", "EPM", "Grupo Exito", "Avianca", "Postobón"]
projects = ["DataLake", "CRM", "ERP", "Analytics", "WebApp"]
months = ["2024-10", "2024-11", "2024-12", "2025-01", "2025-02", "2025-03"]

docs = []
for _ in range(3000):
    total = round(random.uniform(500, 50000), 2)
    waste = round(total * random.uniform(0.1, 0.5), 2)
    docs.append({
        "company": random.choice(companies),
        "project": random.choice(projects),
        "month": random.choice(months),
        "total_cost": total,
        "waste_cost": waste,
        "currency": "USD",
        "resources_analyzed": random.randint(10, 500),
        "created_at": datetime.utcnow()
    })

db["cost_reports"].insert_many(docs)

summaries = []
for company in companies:
    for month in months:
        summaries.append({
            "company": company,
            "month": month,
            "total_cost": round(random.uniform(10000, 200000), 2),
            "total_waste": round(random.uniform(1000, 50000), 2),
            "top_project": random.choice(projects)
        })

db["monthly_summaries"].insert_many(summaries)
print("MongoDB: 3000 cost_reports + 30 monthly_summaries insertados")
