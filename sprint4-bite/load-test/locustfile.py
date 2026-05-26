from locust import HttpUser, task, between, constant, events
import json, requests, os

# ─── CONFIG ──────────────────────────────────────────────────────────────────
# El token se genera automáticamente al arrancar Locust.
# Solo necesitas pasar --host http://<GW-IP>:8000 al correr locust.
# ─────────────────────────────────────────────────────────────────────────────

_token_cache = {}

def get_token(host: str) -> str:
    """Genera un JWT válido llamando al endpoint /auth/token del gateway."""
    if host in _token_cache:
        return _token_cache[host]
    try:
        resp = requests.post(
            f"{host}/auth/token",
            json={"username": "locust-test"},
            timeout=5
        )
        token = resp.json()["token"]
        _token_cache[host] = token
        print(f"[LOCUST] Token obtenido: {token[:40]}...")
        return token
    except Exception as e:
        print(f"[LOCUST] ERROR obteniendo token: {e}")
        return "token-invalido"


class LatencyUser(HttpUser):
    """
    EXP 03 — ASR Latencia
    Simula usuario normal consultando el dashboard agregado (PostgreSQL + MongoDB).
    Correr con:
        locust -f locustfile.py LatencyUser --host http://<GW-IP>:8000 \
               --users 50 --spawn-rate 5 --run-time 120s --headless \
               --csv=results_latency
    """
    wait_time = between(1, 3)

    def on_start(self):
        self.token = get_token(self.host)
        self.headers = {"Authorization": f"Bearer {self.token}"}

    @task(3)
    def dashboard_summary(self):
        """Endpoint principal del ASR: agrega datos de ambas BDs en paralelo."""
        self.client.get(
            "/dashboard/summary",
            headers=self.headers,
            name="[ASR-Latencia] dashboard_summary"
        )

    @task(1)
    def inventory_resources(self):
        self.client.get(
            "/inventory/resources?company=Bancolombia",
            headers=self.headers,
            name="[Latencia] inventory_resources"
        )

    @task(1)
    def report_costs(self):
        self.client.get(
            "/reports/costs?company=Bancolombia",
            headers=self.headers,
            name="[Latencia] report_costs"
        )

    @task(1)
    def monthly_report(self):
        self.client.get(
            "/reports/costs/monthly/Bancolombia",
            headers=self.headers,
            name="[Latencia] monthly_report"
        )


class AttackUser(HttpUser):
    """
    EXP 02 — ASR Seguridad
    Simula atacante enviando ráfaga desde un único origen (sin token válido).
    Correr en terminal SEPARADA con:
        locust -f locustfile.py AttackUser --host http://<GW-IP>:8000 \
               --users 50 --spawn-rate 50 --run-time 60s --headless \
               --csv=results_attack
    Evidencia esperada: respuestas HTTP 429 y logs [AUDIT] BLOCKED en el gateway.
    """
    wait_time = constant(0)

    @task
    def flood_inventory(self):
        self.client.get(
            "/inventory/resources",
            headers={"Authorization": "Bearer token_invalido_ataque"},
            name="[ASR-Seguridad] attack_flood"
        )

    @task
    def flood_dashboard(self):
        self.client.get(
            "/dashboard/summary",
            headers={"Authorization": "Bearer token_invalido_ataque"},
            name="[ASR-Seguridad] attack_dashboard"
        )


class TradeoffUser(HttpUser):
    """
    Trade-off Seguridad vs Latencia
    Misma carga que LatencyUser pero para comparar con/sin rate limiter.
    Correr DOS veces:
      1. Con rate limiter activo (normal)  → --csv=results_tradeoff_con_seguridad
      2. Comentar app.use(limiter) en index.js y rebuild → --csv=results_tradeoff_sin_seguridad
    Comparar p95 entre ambos CSV para documentar el trade-off.
    """
    wait_time = between(1, 2)

    def on_start(self):
        self.token = get_token(self.host)
        self.headers = {"Authorization": f"Bearer {self.token}"}

    @task
    def dashboard_summary(self):
        self.client.get(
            "/dashboard/summary",
            headers=self.headers,
            name="[Tradeoff] dashboard_summary"
        )