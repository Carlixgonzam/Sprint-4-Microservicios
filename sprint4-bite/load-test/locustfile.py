from locust import HttpUser, task, between, constant
import json

TOKEN = "PEGAR_TOKEN_AQUI"

class LatencyUser(HttpUser):
    wait_time = between(1, 3)
    headers = {"Authorization": f"Bearer {TOKEN}"}

    @task(3)
    def dashboard_summary(self):
        self.client.get("/dashboard/summary", headers=self.headers, name="dashboard_summary")

    @task(1)
    def inventory_resources(self):
        self.client.get("/inventory/resources?company=Bancolombia", headers=self.headers, name="inventory_resources")

    @task(1)
    def report_costs(self):
        self.client.get("/reports/costs?company=Bancolombia", headers=self.headers, name="report_costs")

class AttackUser(HttpUser):
    wait_time = constant(0)

    @task
    def flood(self):
        self.client.get(
            "/inventory/resources",
            headers={"Authorization": "Bearer token_invalido"},
            name="attack_flood"
        )
