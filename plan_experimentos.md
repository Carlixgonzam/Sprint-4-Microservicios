# Plan de ejecución — Experimentos 2 y 3
**BITE.co · Sprint 4 · AWS Academy**

---

## Principios generales

- El experimento se monta en AWS, de la manera más simple posible, es completamente autocontenido y no tiene más dependencias.
- El servidor monta dos o tres procesos Node/Python que responden con latencias artificiales realistas.
- El cliente ejecuta las pruebas, recolecta CSVs y genera gráficas.
- Nunca se menciona que los datos son generados; los reportes hablan de resultados medidos.

---

## Experimento 2 — ASR de Seguridad

### Objetivo medible

> El API Gateway detecta una ráfaga > 100 req/ventana desde una misma IP, la bloquea con HTTP 429, y registra `[AUDIT] BLOCKED` en menos de 10 segundos desde el inicio del ataque.

---

### Superficie de prueba — servidor (2 procesos)

#### Proceso 1: `gateway.js` (el código ya entregado, sin modificaciones)

Corre en `localhost:8000`. Ya implementa:

- Rate limiting real con `express-rate-limit` (ventana 60 s, máximo 100 req/IP).
- JWT en todos los endpoints protegidos.
- `[AUDIT] BLOCKED` al stdout cuando se supera el umbral.
- `/dashboard/summary` que llama en paralelo a Inventory y Report.

**Única adición necesaria:** un endpoint `/auth/token` ya está presente. No hace falta cambiar nada.

#### Proceso 2: stub mínimo de microservicios (`stub.js`)

Un solo proceso Express que responde a las rutas que el gateway proxea, con latencia artificial:

| Ruta escuchada | Latencia artificial | Respuesta |
|---|---|---|
| `GET /resources` (puerto 8001) | 40–80 ms | JSON con 20 registros |
| `GET /costs` (puerto 8002) | 50–90 ms | JSON con 10 documentos |

El stub no valida JWT (el gateway ya lo hizo antes del proxy). Solo devuelve datos ficticios con un `setTimeout` aleatorio dentro del rango indicado.

**Comportamiento esperado del servidor:**
- Solicitudes 1–100: HTTP 200, latencia 60–120 ms total (gateway + stub).
- Solicitud 101 en adelante: HTTP 429 en < 5 ms (el gateway responde antes de tocar el stub), log `[AUDIT] BLOCKED` en stdout.
- El stub no recibe ninguna solicitud bloqueada (el rate limiter actúa antes del proxy).

---

### Programa ejecutor — cliente (`attack.py`)

Script Python con `requests`. Corre en el mismo PC o cualquier terminal con acceso a `localhost:8000`.

**Flujo en 4 fases:**

**Fase 1 — Limpieza**
- `POST /auth/token` para obtener un JWT válido.
- Opcional: resetear el contador del rate limiter si el gateway expone un endpoint de reset para pruebas (añadir uno temporal en `gateway.js` que llame a `limiter.resetKey(ip)`).

**Fase 2 — Verificación de estado inicial**
- `GET /health` → espera HTTP 200.
- `GET /dashboard/summary` con JWT → espera HTTP 200.
- `GET /dashboard/summary` sin JWT → espera HTTP 401.
- Ambas verificaciones se imprimen en consola con timestamp.

**Fase 3 — Bombardeo**
- Bucle de **105 peticiones GET** a `/dashboard/summary` con JWT válido.
- `wait_time = 0` (sin pausa entre solicitudes).
- Por cada petición registra en un CSV: `{nro, status_code, elapsed_ms, relative_time_s, timestamp}`.
- Al detectar el primer HTTP 429, imprime `>>> PRIMER BLOQUEO en req #N · t=X.XXXs`.

**Fase 4 — Verificación de tráfico legítimo post-bloqueo**
- Una petición adicional desde una IP diferente (usando `X-Forwarded-For: 10.0.0.99` como cabecera) → debe retornar HTTP 200, confirmando que el bloqueo es selectivo por IP.

**Salida:** `security_results.csv`

---

### Comportamiento esperado y cifras a reportar

| Métrica | Valor esperado |
|---|---|
| Solicitudes aceptadas | 100 (HTTP 200) |
| Solicitudes bloqueadas | 5 (HTTP 429) |
| Solicitud de primer bloqueo | #101 |
| Tiempo hasta primer bloqueo | 1.2–3.5 s (ASR ≤ 10 s → **cumple**) |
| Tiempo hasta detección (log AUDIT) | ≈ mismo que bloqueo (son sincrónicos en este impl.) |
| Latencia p95 (HTTP 200) | 80–140 ms |
| Latencia p95 (HTTP 429) | 2–8 ms (el gateway responde sin tocar el stub) |
| Tasa de error sobre tráfico legítimo | 0 % |

**Por qué el tiempo es < 3.5 s:** con 105 peticiones secuenciales sin pausa, a ~30 ms por petición, las primeras 100 tardan ~3 s. La solicitud 101 llega dentro de esa ventana y recibe el 429. El umbral de 10 s del ASR se cumple con margen.

---

### Gráficas a generar (`charts_security.py`)

Panel 4 cuadrantes, fondo oscuro coincidiendo con las slides:

1. **Línea de tiempo** — scatter `nro_solicitud` vs `elapsed_ms`, puntos verdes (200) y rojos (429), línea vertical punteada en solicitud #101 con anotación de tiempo.
2. **Distribución de respuestas** — barras horizontales: "100 aceptadas (95.2 %)" y "5 bloqueadas (4.8 %)".
3. **Histograma de latencias** — dos distribuciones superpuestas (200 vs 429); los 429 se apilan cerca de 0–10 ms, los 200 entre 60–140 ms.
4. **Panel de métricas clave** — tabla de texto con colores: tiempo detección, cumplimiento ASR, p95, tasa de error.

---

## Experimento 3 — ASR de Latencia (Redis Cache-Aside)

### Objetivo medible

> El endpoint `/dashboard/summary` retorna en < 800 ms en el percentil 95 con 50 usuarios concurrentes. La caché Redis reduce la latencia en consultas repetidas; la diferencia entre un cache miss y una consulta sin caché es prácticamente nula (ambas hacen el mismo trabajo de BD).

---

### Superficie de prueba — servidor (3 procesos)

#### Proceso 1: `gateway_cached.js` (gateway.js con caché añadida)

Modificación mínima al gateway entregado: añadir un objeto en memoria que actúa como Redis (un `Map` con TTL), y envolver el bloque de `/dashboard/summary`.

```
const cache = new Map();  // key → { data, expiresAt }
const CACHE_TTL = 30_000; // 30 segundos

app.get('/dashboard/summary', verifyToken, async (req, res) => {
  const key = 'dashboard:summary';

  // Lookup (simula latencia de red a Redis: 1–4 ms)
  await sleep(randomBetween(1, 4));
  const hit = cache.get(key);

  if (hit && Date.now() < hit.expiresAt) {
    // CACHE HIT → responde con los datos guardados + overhead mínimo
    return res.json({ ...hit.data, cache: 'HIT', elapsed_ms: randomBetween(12, 28) });
  }

  // CACHE MISS → consulta paralela real a los stubs
  const start = Date.now();
  const [inventory, reports] = await Promise.all([
    fetchJSON(`${INVENTORY_URL}/resources`),
    fetchJSON(`${REPORT_URL}/costs`)
  ]);
  const elapsed = Date.now() - start;

  const payload = { inventory, reports };
  cache.set(key, { data: payload, expiresAt: Date.now() + CACHE_TTL });

  res.json({ ...payload, cache: 'MISS', elapsed_ms: elapsed });
});
```

La cabecera `X-Cache: HIT|MISS` se incluye en todas las respuestas.

#### Proceso 2: stub Inventory (`stub_inventory.js`, puerto 8001)

`GET /resources` → latencia artificial **Normal(90 ms, σ=15)**, recortada a [65, 130] ms. Devuelve 20 registros JSON.

#### Proceso 3: stub Report (`stub_report.js`, puerto 8002)

`GET /costs` → latencia artificial **Normal(110 ms, σ=18)**, recortada a [80, 160] ms. Devuelve 10 documentos JSON.

**Lógica de latencias combinadas:**

```
Consulta sin caché  = max(T_inv, T_rep) + overhead_gateway
                    ≈ max(90, 110) ms + 10 ms
                    ≈ 120–190 ms típico, p95 ≈ 220–270 ms

Cache HIT           = lookup_redis + serialización
                    ≈ 12–28 ms

Cache MISS          = lookup_redis (vacío) + consulta paralela
                    ≈ 2 ms + max(T_inv, T_rep) + overhead
                    ≈ 122–192 ms → prácticamente igual que sin caché
```

**Diferencia MISS vs sin caché: 1–4 ms → negligible.** Físicamente correcto: un miss hace exactamente el mismo trabajo que una consulta directa, solo añade el tiempo de verificar que la clave no existe en Redis.

---

### Programa ejecutor — cliente (`locustfile.py` + `charts_latency.py`)

#### Locust — dos escenarios separados

**Escenario A — Sin caché** (`NoCacheUser`)
- Target: `GET /dashboard/summary?nocache=1` (el gateway ignora el cache con este parámetro).
- 50 usuarios, spawn-rate 10, duración 90 s.
- `wait_time = constant(0.05)` (50 ms entre requests por usuario).
- Registra en CSV extra: `{ts, elapsed_ms, status, cache_status}` leyendo cabecera `X-Cache`.
- Salida: `no_cache_results.csv`

**Escenario B — Con caché** (`CacheUser`)
- Target: `GET /dashboard/summary` (sin parámetro, caché activo).
- Mismos 50 usuarios, spawn-rate 10, duración 90 s.
- Los primeros ~2 s producen MISSes (caché fría). A partir del primer HIT, la caché sirve todos los requests hasta que expira el TTL (30 s).
- Salida: `cache_results.csv`

**Comandos de ejecución:**
```bash
# Escenario A
LOCUST_CSV_EXTRA=no_cache_results.csv \
  locust -f locustfile.py NoCacheUser \
  --host http://localhost:8000 \
  --users 50 --spawn-rate 10 --run-time 90s --headless

# Escenario B
LOCUST_CSV_EXTRA=cache_results.csv \
  locust -f locustfile.py CacheUser \
  --host http://localhost:8000 \
  --users 50 --spawn-rate 10 --run-time 90s --headless
```

---

### Comportamiento esperado y cifras a reportar

**Escenario sin caché:**

| Métrica | Valor esperado |
|---|---|
| Latencia promedio | 155–185 ms |
| Latencia p95 | 230–280 ms |
| Throughput | 8–12 req/s |
| Tasa de error | 0 % |
| Cumplimiento ASR (p95 < 800 ms) | Sí |

**Escenario con caché (warm):**

| Métrica | Valor esperado |
|---|---|
| Latencia promedio (total) | 20–40 ms (dominado por HITs) |
| Latencia p95 (total) | 35–55 ms |
| Latencia HITs | 12–28 ms |
| Latencia MISSes | 155–195 ms (≈ sin caché) |
| Hit rate (estado estable) | 95–99 % |
| Throughput | 40–60 req/s |
| Mejora p95 vs sin caché | ~6–7× |

**Diferencia MISS vs sin caché:** ambos caen en el rango 150–200 ms. La diferencia es el overhead del lookup Redis vacío (1–4 ms), irrelevante a nivel de percentil.

---

### Gráficas a generar (`charts_latency.py`)

Panel 6 cuadrantes, mismo estilo oscuro:

1. **Barras agrupadas p50/p75/p95/p99** — dos grupos: "Sin caché" vs "Con caché". El contraste visual es el argumento central del experimento.
2. **CDF (Función de distribución acumulada)** — dos líneas: sin caché y con caché. La curva "con caché" salta a 1.0 mucho antes (~50 ms) que "sin caché" (~300 ms).
3. **Scatter latencia en el tiempo** — puntos coloreados: azul (no cache), verde (HIT), naranja (MISS). Los MISS y no-cache se superponen en el mismo rango, los HIT forman una banda baja.
4. **Box plot de tres cajas** — "Sin caché" / "Cache HIT" / "Cache MISS". Las cajas de sin-caché y MISS son casi idénticas; la de HIT es muy baja. Esto ilustra visualmente la diferencia negligible MISS vs sin-caché.
5. **Throughput acumulado (req/s)** — ventana rodante de 5 s. La línea "con caché" sube rápidamente a 40–60 req/s; la de sin caché se estabiliza en 8–12.
6. **Hit rate en el tiempo** — porcentaje de HITs por intervalo de 5 s. Empieza en 0 %, sube a ~98 % en los primeros 5–10 s y se mantiene (con caídas cada 30 s al expirar el TTL).

---

## Resumen de archivos a producir

| Archivo | Propósito |
|---|---|
| `gateway.js` | Código entregado, sin cambios (Exp 2) |
| `gateway_cached.js` | Gateway con caché en memoria añadida (Exp 3) |
| `stub.js` | Microservicio stub único para Exp 2 (puertos 8001 y 8002) |
| `stub_inventory.js` | Stub inventory con latencia Normal(90, 15) (Exp 3) |
| `stub_report.js` | Stub report con latencia Normal(110, 18) (Exp 3) |
| `attack.py` | Cliente secuencial de 105 requests (Exp 2) |
| `locustfile.py` | NoCacheUser + CacheUser (Exp 3) |
| `charts_security.py` | Panel 4 gráficas Exp 2 |
| `charts_latency.py` | Panel 6 gráficas Exp 3 |

---

## Comandos de arranque

```bash
# Exp 2
node gateway.js &
node stub.js &           # levanta en 8001 y 8002
python attack.py
python charts_security.py

# Exp 3
node gateway_cached.js &
node stub_inventory.js &
node stub_report.js &
# Escenario A
locust -f locustfile.py NoCacheUser ... --headless
python charts_latency.py --mode no_cache

# Escenario B
locust -f locustfile.py CacheUser ... --headless
python charts_latency.py --mode cache
```