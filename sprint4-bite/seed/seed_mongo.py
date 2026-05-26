from pymongo import MongoClient, DESCENDING
import random
from datetime import datetime

# ─── PONER LA IP PÚBLICA DE ec2-mongo AQUÍ ───────────────────────────────────
EC2_MONGO_IP = "REEMPLAZAR_CON_IP_DE_EC2_MONGO"
# ─────────────────────────────────────────────────────────────────────────────

MONGO_URL = f"mongodb://{EC2_MONGO_IP}:27017"

client = MongoClient(MONGO_URL)
db = client["bite_reports"]

companies = ["Bancolombia", "EPM", "Grupo Exito", "Avianca", "Postobón"]
projects  = ["DataLake", "CRM", "ERP", "Analytics", "WebApp"]
months    = ["2024-10", "2024-11", "2024-12", "2025-01", "2025-02", "2025-03"]

# Índices para mejorar latencia (táctica ASR-02)
print("Creando índices en MongoDB...")
db["cost_reports"].create_index([("company", DESCENDING)])
db["cost_reports"].create_index([("company", DESCENDING), ("project", DESCENDING)])
db["cost_reports"].create_index([("month", DESCENDING)])
db["monthly_summaries"].create_index([("company", DESCENDING), ("month", DESCENDING)])

# cost_reports: 3000 documentos
print("Insertando 3000 cost_reports...")
docs = []
for _ in range(3000):
    total = round(random.uniform(500, 50000), 2)
    waste = round(total * random.uniform(0.1, 0.5), 2)
    docs.append({
        "company":            random.choice(companies),
        "project":            random.choice(projects),
        "month":              random.choice(months),
        "total_cost":         total,
        "waste_cost":         waste,
        "currency":           "USD",
        "resources_analyzed": random.randint(10, 500),
        "created_at":         datetime.utcnow()
    })
db["cost_reports"].insert_many(docs)

# monthly_summaries: 1 doc por empresa/mes (30 docs)
print("Insertando 30 monthly_summaries...")
summaries = []
for company in companies:
    for month in months:
        summaries.append({
            "company":     company,
            "month":       month,
            "total_cost":  round(random.uniform(10000, 200000), 2),
            "total_waste": round(random.uniform(1000, 50000), 2),
            "top_project": random.choice(projects)
        })
db["monthly_summaries"].insert_many(summaries)

print("✅ MongoDB: 3000 cost_reports + 30 monthly_summaries + índices creados")