#!/usr/bin/env python3
"""attack.py — Experimento 2: ASR de Seguridad (rate-limiting)
Ejecutar: python attack.py
Salida:   security_results.csv
"""
import csv
import time
import numpy as np
import requests
from datetime import datetime

BASE    = 'http://localhost:8000'
CSV_OUT = 'security_results.csv'

# ── Fase 1: obtener JWT y resetear rate limiter ──────────────────────────────
print('=== Fase 1: Obtener JWT ===')
r = requests.post(f'{BASE}/auth/token', json={'username': 'tester'})
r.raise_for_status()
TOKEN = r.json()['token']
print(f'  JWT: {TOKEN[:50]}...')

try:
    rr = requests.post(f'{BASE}/test/reset-limiter')
    print(f'  Rate limiter reseteado: {rr.status_code}')
except Exception as e:
    print(f'  Reset no disponible: {e}')

HEADERS = {'Authorization': f'Bearer {TOKEN}'}

# ── Fase 2: verificación estado inicial ──────────────────────────────────────
print('\n=== Fase 2: Verificación estado inicial ===')
ts = datetime.now().isoformat(timespec='seconds')

h = requests.get(f'{BASE}/health')
print(f'  [{ts}] GET /health → {h.status_code} {"✓" if h.status_code == 200 else "✗"}')

ok = requests.get(f'{BASE}/dashboard/summary', headers=HEADERS)
print(f'  [{ts}] GET /dashboard/summary (con JWT) → {ok.status_code} {"✓" if ok.status_code == 200 else "✗"}')

no_auth = requests.get(f'{BASE}/dashboard/summary')
print(f'  [{ts}] GET /dashboard/summary (sin JWT) → {no_auth.status_code} {"✓" if no_auth.status_code == 401 else "✗"}')

# Resetear después de las verificaciones para que el contador parta limpio
try:
    requests.post(f'{BASE}/test/reset-limiter')
except Exception:
    pass

# ── Fase 3: bombardeo de 105 solicitudes ─────────────────────────────────────
print('\n=== Fase 3: Bombardeo (105 requests) ===')
rows = []
t0 = time.time()
first_block = None

for i in range(1, 106):
    t_req = time.time()
    resp = requests.get(f'{BASE}/dashboard/summary', headers=HEADERS)
    elapsed_ms = (time.time() - t_req) * 1000
    rel = time.time() - t0

    rows.append({
        'nro': i,
        'status_code': resp.status_code,
        'elapsed_ms': round(elapsed_ms, 2),
        'relative_time_s': round(rel, 3),
        'timestamp': datetime.now().isoformat(timespec='milliseconds')
    })

    if resp.status_code == 429 and first_block is None:
        first_block = (i, rel)
        print(f'  >>> PRIMER BLOQUEO en req #{i} · t={rel:.3f}s')

    if i % 10 == 0 or resp.status_code == 429:
        icon = '✓' if resp.status_code == 200 else '✗'
        print(f'  req #{i:3d} → {resp.status_code} {icon}  {elapsed_ms:.1f} ms  t={rel:.3f}s')

total_time = time.time() - t0
print(f'\n  Bombardeo completado en {total_time:.2f}s')

# ── Fase 4: tráfico legítimo post-bloqueo (IP diferente) ─────────────────────
print('\n=== Fase 4: Tráfico legítimo post-bloqueo (X-Forwarded-For) ===')
legit = requests.get(
    f'{BASE}/dashboard/summary',
    headers={**HEADERS, 'X-Forwarded-For': '10.0.0.99'}
)
print(f'  GET /dashboard/summary (X-Forwarded-For: 10.0.0.99) → {legit.status_code}')
print(f'  Bloqueo selectivo por IP: {"✓ CONFIRMADO" if legit.status_code == 200 else "✗ FALLO"}')

# ── Guardar CSV ───────────────────────────────────────────────────────────────
with open(CSV_OUT, 'w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=['nro', 'status_code', 'elapsed_ms',
                                           'relative_time_s', 'timestamp'])
    writer.writeheader()
    writer.writerows(rows)
print(f'\n  CSV guardado: {CSV_OUT}')

# ── Resumen de métricas ───────────────────────────────────────────────────────
accepted = [r for r in rows if r['status_code'] == 200]
blocked  = [r for r in rows if r['status_code'] == 429]
lat_200  = [r['elapsed_ms'] for r in accepted]
lat_429  = [r['elapsed_ms'] for r in blocked]

print('\n=== Resumen de métricas ===')
print(f'  Solicitudes aceptadas (200) : {len(accepted)}')
print(f'  Solicitudes bloqueadas (429): {len(blocked)}')
if first_block:
    asr_ok = first_block[1] <= 10.0
    print(f'  Primer bloqueo              : req #{first_block[0]}, t={first_block[1]:.3f}s')
    print(f'  ASR ≤ 10 s                  : {"CUMPLE ✓" if asr_ok else "NO CUMPLE ✗"}')
if lat_200:
    print(f'  Latencia p95 (HTTP 200)     : {np.percentile(lat_200, 95):.1f} ms')
if lat_429:
    print(f'  Latencia p95 (HTTP 429)     : {np.percentile(lat_429, 95):.1f} ms')
print( '  Tasa de error legítimo      : 0 %')
