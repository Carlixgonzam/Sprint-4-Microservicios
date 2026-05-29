"""locustfile.py — Experimento 3: ASR de Latencia (Redis Cache-Aside)

Escenario A (sin caché):
  locust -f locustfile.py NoCacheUser \\
    --host http://localhost:8000 \\
    --users 50 --spawn-rate 10 --run-time 90s --headless

Escenario B (con caché):
  locust -f locustfile.py CacheUser \\
    --host http://localhost:8000 \\
    --users 50 --spawn-rate 10 --run-time 90s --headless

Salidas: no_cache_results.csv  /  cache_results.csv
"""
import csv
import time
import threading
from locust import HttpUser, task, constant, events

# ── CSV writers con lock para acceso concurrente ──────────────────────────────
_lock = threading.Lock()

_no_cache_file   = None
_no_cache_writer = None
_cache_file      = None
_cache_writer    = None

FIELDNAMES = ['ts', 'elapsed_ms', 'status', 'cache_status']


@events.init.add_listener
def on_init(environment, **kwargs):
    global _no_cache_file, _no_cache_writer, _cache_file, _cache_writer

    _no_cache_file = open('no_cache_results.csv', 'w', newline='', encoding='utf-8')
    _no_cache_writer = csv.DictWriter(_no_cache_file, fieldnames=FIELDNAMES)
    _no_cache_writer.writeheader()

    _cache_file = open('cache_results.csv', 'w', newline='', encoding='utf-8')
    _cache_writer = csv.DictWriter(_cache_file, fieldnames=FIELDNAMES)
    _cache_writer.writeheader()


@events.quitting.add_listener
def on_quit(environment, **kwargs):
    if _no_cache_file:
        _no_cache_file.close()
    if _cache_file:
        _cache_file.close()


def _get_token(client):
    resp = client.post('/auth/token', json={'username': 'locust-user'}, name='/auth/token')
    if resp.status_code == 200:
        return resp.json().get('token', '')
    return ''


# ── Escenario A: sin caché ────────────────────────────────────────────────────
class NoCacheUser(HttpUser):
    wait_time = constant(0.05)  # 50 ms entre requests por usuario

    def on_start(self):
        self.token = _get_token(self.client)

    @task
    def get_no_cache(self):
        headers = {'Authorization': f'Bearer {self.token}'}
        with self.client.get(
            '/dashboard/summary?nocache=1',
            headers=headers,
            name='/dashboard/summary?nocache=1',
            catch_response=True
        ) as resp:
            cache_status = resp.headers.get('X-Cache', 'BYPASS')
            row = {
                'ts':           time.time(),
                'elapsed_ms':   resp.elapsed.total_seconds() * 1000,
                'status':       resp.status_code,
                'cache_status': cache_status,
            }
            with _lock:
                if _no_cache_writer:
                    _no_cache_writer.writerow(row)
            if resp.status_code == 200:
                resp.success()
            else:
                resp.failure(f'HTTP {resp.status_code}')


# ── Escenario B: con caché ────────────────────────────────────────────────────
class CacheUser(HttpUser):
    wait_time = constant(0.05)

    def on_start(self):
        self.token = _get_token(self.client)

    @task
    def get_cached(self):
        headers = {'Authorization': f'Bearer {self.token}'}
        with self.client.get(
            '/dashboard/summary',
            headers=headers,
            name='/dashboard/summary',
            catch_response=True
        ) as resp:
            cache_status = resp.headers.get('X-Cache', 'UNKNOWN')
            row = {
                'ts':           time.time(),
                'elapsed_ms':   resp.elapsed.total_seconds() * 1000,
                'status':       resp.status_code,
                'cache_status': cache_status,
            }
            with _lock:
                if _cache_writer:
                    _cache_writer.writerow(row)
            if resp.status_code == 200:
                resp.success()
            else:
                resp.failure(f'HTTP {resp.status_code}')
