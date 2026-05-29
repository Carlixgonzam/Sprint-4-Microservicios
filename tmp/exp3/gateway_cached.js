// gateway_cached.js — API Gateway con cache-aside en memoria (Experimento 3)
// Expone X-Cache: HIT|MISS|BYPASS en todas las respuestas de /dashboard/summary
// Parámetro ?nocache=1 salta la caché (usado por el escenario NoCacheUser de Locust)
const express = require('express');
const rateLimit = require('express-rate-limit');
const jwt = require('jsonwebtoken');
const morgan = require('morgan');
const http = require('http');

const app = express();
app.set('trust proxy', true);
app.use(morgan('combined'));
app.use(express.json());

const JWT_SECRET = process.env.JWT_SECRET || 'bite-secret-2025';

// Rate limit más alto para el experimento de latencia (no queremos bloqueos)
const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5000,
  standardHeaders: true,
  legacyHeaders: false,
  handler: (req, res) => {
    console.log(`[AUDIT] BLOCKED ${req.ip} - ${new Date().toISOString()}`);
    res.status(429).json({ error: 'Too Many Requests' });
  }
});
app.use(limiter);

function verifyToken(req, res, next) {
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing token' });
  }
  try {
    req.user = jwt.verify(auth.split(' ')[1], JWT_SECRET);
    next();
  } catch (e) {
    return res.status(403).json({ error: 'Invalid token' });
  }
}

app.post('/auth/token', (req, res) => {
  const { username } = req.body;
  if (!username) return res.status(400).json({ error: 'username required' });
  const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '24h' });
  res.json({ token });
});

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'api-gateway-cached' }));

const INVENTORY_URL = process.env.INVENTORY_URL || 'http://localhost:8001';
const REPORT_URL    = process.env.REPORT_URL    || 'http://localhost:8002';

const cache     = new Map();
const CACHE_TTL = 30_000; // 30 s

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function randInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function fetchJSON(url) {
  return new Promise((resolve, reject) => {
    http.get(url, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(e); }
      });
    }).on('error', reject);
  });
}

app.get('/dashboard/summary', verifyToken, async (req, res) => {
  const noCache = req.query.nocache === '1';
  const key     = 'dashboard:summary';

  if (!noCache) {
    // Simula latencia de red a Redis (1–4 ms)
    await sleep(randInt(1, 4));
    const hit = cache.get(key);

    if (hit && Date.now() < hit.expiresAt) {
      res.set('X-Cache', 'HIT');
      return res.json({
        ...hit.data,
        cache: 'HIT',
        elapsed_ms: randInt(12, 28)
      });
    }
  }

  // CACHE MISS o bypass → consulta paralela a stubs
  const start = Date.now();
  try {
    const [inventory, reports] = await Promise.all([
      fetchJSON(`${INVENTORY_URL}/resources`),
      fetchJSON(`${REPORT_URL}/costs`)
    ]);
    const elapsed  = Date.now() - start;
    const payload  = { inventory, reports };

    if (!noCache) {
      cache.set(key, { data: payload, expiresAt: Date.now() + CACHE_TTL });
      res.set('X-Cache', 'MISS');
    } else {
      res.set('X-Cache', 'BYPASS');
    }

    res.json({ ...payload, cache: noCache ? 'BYPASS' : 'MISS', elapsed_ms: elapsed });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.listen(8000, () => console.log('[EXP3] API Gateway (cached) corriendo en :8000'));
