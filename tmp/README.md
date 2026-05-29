# Experimentos 2 y 3 — BITE.co Sprint 4

## Setup único (una vez)

```bash
# Python
pip install -r requirements.txt

# Node — Experimento 2
cd exp2 && npm install && cd ..

# Node — Experimento 3
cd exp3 && npm install && cd ..
```

---

## Experimento 2 — ASR de Seguridad

```bash
# Terminal 1: servidores
cd exp2
node gateway.js &   # :8000
node stub.js        # :8001 y :8002

# Terminal 2: ejecutor + gráficas (en exp2/)
python attack.py
python charts_security.py
# Salidas: security_results.csv, security_charts.png
```

---

## Experimento 3 — ASR de Latencia (Cache-Aside)

```bash
# Terminal 1: servidores
cd exp3
node gateway_cached.js &   # :8000
node stub_inventory.js &   # :8001
node stub_report.js        # :8002

# Terminal 2: Escenario A — sin caché (en exp3/)
locust -f locustfile.py NoCacheUser \
  --host http://localhost:8000 \
  --users 50 --spawn-rate 10 --run-time 90s --headless

# Terminal 2: Escenario B — con caché
locust -f locustfile.py CacheUser \
  --host http://localhost:8000 \
  --users 50 --spawn-rate 10 --run-time 90s --headless

# Gráficas (después de ambos escenarios)
python charts_latency.py
# Salidas: no_cache_results.csv, cache_results.csv, latency_charts.png
```
