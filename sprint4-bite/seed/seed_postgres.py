import psycopg2
import random

# ─── PONER LA IP PÚBLICA DE ec2-postgres AQUÍ ────────────────────────────────
EC2_POSTGRES_IP = "REEMPLAZAR_CON_IP_DE_EC2_POSTGRES"
# ─────────────────────────────────────────────────────────────────────────────

conn = psycopg2.connect(
    host=EC2_POSTGRES_IP,
    database="inventory",
    user="bite",
    password="bite123"
)
cur = conn.cursor()

cur.execute("""
    CREATE TABLE IF NOT EXISTS cloud_resources (
        id SERIAL PRIMARY KEY,
        company VARCHAR(100),
        project VARCHAR(100),
        provider VARCHAR(50),
        resource_type VARCHAR(100),
        region VARCHAR(50),
        status VARCHAR(20),
        cpu_usage FLOAT,
        memory_gb FLOAT,
        monthly_cost FLOAT,
        created_at TIMESTAMP DEFAULT NOW()
    );
""")

# Índices para mejorar latencia de consultas (táctica ASR-02)
# Escenario "con índice" del experimento de latencia
cur.execute("""
    CREATE INDEX IF NOT EXISTS idx_company
        ON cloud_resources(company);
""")
cur.execute("""
    CREATE INDEX IF NOT EXISTS idx_company_project
        ON cloud_resources(company, project);
""")

companies = ["Bancolombia", "EPM", "Grupo Exito", "Avianca", "Postobón"]
projects  = ["DataLake", "CRM", "ERP", "Analytics", "WebApp"]
providers = ["AWS", "GCP", "Azure"]
rtypes    = ["EC2", "RDS", "S3", "Lambda", "BigQuery", "GKE", "AzureVM"]
regions   = ["us-east-1", "us-west-2", "eu-west-1", "sa-east-1"]

print("Insertando 5000 registros en PostgreSQL...")
for i in range(5000):
    cur.execute("""
        INSERT INTO cloud_resources
        (company, project, provider, resource_type, region, status,
         cpu_usage, memory_gb, monthly_cost)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
    """, (
        random.choice(companies),
        random.choice(projects),
        random.choice(providers),
        random.choice(rtypes),
        random.choice(regions),
        random.choice(["running", "stopped", "idle"]),
        round(random.uniform(0, 100), 2),
        round(random.uniform(0.5, 64), 2),
        round(random.uniform(5, 500), 2)
    ))
    if (i + 1) % 1000 == 0:
        print(f"  {i + 1}/5000...")

conn.commit()
cur.close()
conn.close()
print("✅ PostgreSQL: 5000 registros + índices creados")