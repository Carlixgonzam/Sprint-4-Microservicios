const express = require('express');
const rateLimit = require('express-rate-limit');
const { createProxyMiddleware } = require('http-proxy-middleware');
const jwt = require('jsonwebtoken');
const morgan = require('morgan');
const http = require('http');
const { MongoClient } = require('mongodb');

const app = express();
app.use(morgan('combined'));
app.use(express.json());

// ── Config ────────────────────────────────────────────────────────────────────
const JWT_SECRET    = process.env.JWT_SECRET    || 'bite-secret-2025';
const ACCESS_TTL    = process.env.ACCESS_TTL    || '1h';
const REFRESH_TTL   = process.env.REFRESH_TTL   || '7d';

const INVENTORY_URL    = process.env.INVENTORY_URL    || 'http://localhost:8001';
const REPORT_URL       = process.env.REPORT_URL       || 'http://localhost:8002';
const NOTIF_URL        = process.env.NOTIF_URL        || 'http://localhost:8003';
const ORCHESTRATOR_URL = process.env.ORCHESTRATOR_URL || 'http://localhost:8004';

const DEFAULT_CLIENT_ID = process.env.DEFAULT_CLIENT_ID
  || '00000000-0000-0000-0000-000000000001';

const SCOPES = {
  READ_RESOURCES: 'read:own_resources',
  READ_COSTS:     'read:own_costs',
  WRITE_SETTINGS: 'write:settings',
  ADMIN_FULL:     'admin:full',
};

const ROLE_PERMS = {
  user:  [SCOPES.READ_RESOURCES, SCOPES.READ_COSTS],
  admin: [SCOPES.READ_RESOURCES, SCOPES.READ_COSTS, SCOPES.WRITE_SETTINGS, SCOPES.ADMIN_FULL],
};

// ── Audit log → MongoDB (fire-and-forget, never blocks) ──────────────────────
const MONGO_AUDIT_URL = process.env.MONGO_AUDIT_URL || process.env.MONGO_URL
  || 'mongodb://localhost:27017';
const AUDIT_DB  = 'bite_reports';
const AUDIT_COL = 'audit_log';

let auditClient = null;
let auditColPromise = null;
async function getAuditCol() {
  if (!auditColPromise) {
    auditColPromise = (async () => {
      try {
        auditClient = new MongoClient(MONGO_AUDIT_URL, { serverSelectionTimeoutMS: 2000 });
        await auditClient.connect();
        return auditClient.db(AUDIT_DB).collection(AUDIT_COL);
      } catch (e) {
        console.log(`[AUDIT-WARN] MongoDB unavailable: ${e.message}`);
        auditColPromise = null;
        return null;
      }
    })();
  }
  return auditColPromise;
}

function auditLog(entry) {
  // Always console-log for backward compat with existing scripts grepping logs
  console.log(`[AUDIT] ${entry.action || 'event'} ${entry.actor || '-'} ${entry.ip || '-'} ${entry.status || ''}`);
  setImmediate(async () => {
    const col = await getAuditCol();
    if (!col) return;
    try {
      await col.insertOne({ ...entry, timestamp: new Date() });
    } catch (e) {
      console.log(`[AUDIT-WARN] insert failed: ${e.message}`);
    }
  });
}

// ── Rate limiter ──────────────────────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  handler: (req, res) => {
    auditLog({
      action: 'rate_limit_blocked',
      actor: req.user ? req.user.username : null,
      ip: req.ip,
      path: req.path,
      status: 'failure',
    });
    res.status(429).json({
      error: 'Too Many Requests',
      message: 'Rate limit exceeded. Blocked automatically.',
      ip: req.ip,
      timestamp: new Date().toISOString(),
    });
  },
});
app.use(limiter);

// ── Auth ──────────────────────────────────────────────────────────────────────
function verifyToken(req, res, next) {
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing token' });
  }
  try {
    const payload = jwt.verify(auth.split(' ')[1], JWT_SECRET);
    if (payload.type && payload.type !== 'access') {
      return res.status(401).json({ error: 'Wrong token type, use an access token' });
    }
    req.user = payload;
    next();
  } catch (e) {
    auditLog({ action: 'invalid_token', ip: req.ip, path: req.path, status: 'failure' });
    return res.status(403).json({ error: 'Invalid token' });
  }
}

function requireScope(scope) {
  return (req, res, next) => {
    const perms = req.user && req.user.permissions;
    // Backward compat: legacy tokens without 'permissions' claim → allow
    if (!perms) return next();
    if (perms.includes(scope) || perms.includes(SCOPES.ADMIN_FULL)) return next();
    auditLog({
      action: 'forbidden',
      actor: req.user.username,
      ip: req.ip,
      path: req.path,
      required_scope: scope,
      status: 'failure',
    });
    return res.status(403).json({ error: 'Insufficient scope', required: scope });
  };
}

// ── Auth endpoints ────────────────────────────────────────────────────────────
app.post('/auth/token', (req, res) => {
  const { username, role, client_id } = req.body;
  if (!username) return res.status(400).json({ error: 'username required' });

  const resolvedRole = role === 'admin' ? 'admin' : 'user';
  const permissions = ROLE_PERMS[resolvedRole];
  const cid = client_id || DEFAULT_CLIENT_ID;
  const now = Math.floor(Date.now() / 1000);

  const accessToken = jwt.sign(
    { username, client_id: cid, role: resolvedRole, permissions, type: 'access', iat: now },
    JWT_SECRET, { expiresIn: ACCESS_TTL }
  );
  const refreshToken = jwt.sign(
    { username, client_id: cid, role: resolvedRole, type: 'refresh', iat: now },
    JWT_SECRET, { expiresIn: REFRESH_TTL }
  );

  auditLog({ action: 'token_issued', actor: username, client_id: cid, ip: req.ip, status: 'success' });

  // Backward-compatible response: keep `token` field for existing clients
  res.json({
    token: accessToken,
    access_token: accessToken,
    refresh_token: refreshToken,
    token_type: 'Bearer',
    expires_in: 3600,
    permissions,
    client_id: cid,
  });
});

app.post('/auth/refresh', (req, res) => {
  const { refresh_token } = req.body;
  if (!refresh_token) return res.status(400).json({ error: 'refresh_token required' });
  try {
    const payload = jwt.verify(refresh_token, JWT_SECRET);
    if (payload.type !== 'refresh') {
      return res.status(401).json({ error: 'Not a refresh token' });
    }
    const resolvedRole = payload.role === 'admin' ? 'admin' : 'user';
    const permissions = ROLE_PERMS[resolvedRole];
    const now = Math.floor(Date.now() / 1000);
    const accessToken = jwt.sign(
      { username: payload.username, client_id: payload.client_id, role: resolvedRole,
        permissions, type: 'access', iat: now },
      JWT_SECRET, { expiresIn: ACCESS_TTL }
    );
    auditLog({ action: 'token_refreshed', actor: payload.username,
               client_id: payload.client_id, ip: req.ip, status: 'success' });
    res.json({
      token: accessToken,
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: 3600,
      permissions,
    });
  } catch (e) {
    auditLog({ action: 'refresh_failed', ip: req.ip, status: 'failure' });
    res.status(403).json({ error: 'Invalid or expired refresh token' });
  }
});

// ── Health ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'api-gateway' }));

// ── Orchestrator endpoints (MUST be registered before the legacy /reports proxy) ──
const UUID_RE = /^\/reports\/[0-9a-f-]{36}$/i;

app.post('/reports/generate', verifyToken, requireScope(SCOPES.READ_COSTS), async (req, res) => {
  try {
    const body = { ...req.body, client_id: (req.user && req.user.client_id) || req.body.client_id || DEFAULT_CLIENT_ID };
    auditLog({ action: 'report_generate', actor: req.user.username,
               client_id: body.client_id, ip: req.ip, status: 'pending' });
    const upstream = await fetch(`${ORCHESTRATOR_URL}/reports/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await upstream.json();
    res.status(upstream.status).json(data);
  } catch (e) {
    res.status(502).json({ error: 'orchestrator unavailable', detail: e.message });
  }
});

app.get(UUID_RE, verifyToken, requireScope(SCOPES.READ_COSTS), async (req, res) => {
  try {
    const upstream = await fetch(`${ORCHESTRATOR_URL}${req.path}`);
    const data = await upstream.json();
    res.status(upstream.status).json(data);
  } catch (e) {
    res.status(502).json({ error: 'orchestrator unavailable', detail: e.message });
  }
});

// ── Proxies to downstream services ────────────────────────────────────────────
app.use('/inventory', verifyToken, requireScope(SCOPES.READ_RESOURCES), createProxyMiddleware({
  target: INVENTORY_URL, changeOrigin: true,
  pathRewrite: { '^/inventory': '' }
}));

app.use('/reports', verifyToken, requireScope(SCOPES.READ_COSTS), createProxyMiddleware({
  target: REPORT_URL, changeOrigin: true,
  pathRewrite: { '^/reports': '' }
}));

app.use('/notifications', verifyToken, requireScope(SCOPES.READ_COSTS), createProxyMiddleware({
  target: NOTIF_URL, changeOrigin: true,
  pathRewrite: { '^/notifications': '' }
}));

// ── Dashboard aggregator (parallel fan-out — ASR Latency) ─────────────────────
function fetchJSON(url) {
  return new Promise((resolve, reject) => {
    http.get(url, response => {
      let data = '';
      response.on('data', chunk => data += chunk);
      response.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch(e) { reject(e); }
      });
    }).on('error', reject);
  });
}

app.get('/dashboard/summary', verifyToken, requireScope(SCOPES.READ_COSTS), async (req, res) => {
  const start = Date.now();
  try {
    const [inventory, reports] = await Promise.all([
      fetchJSON(`${INVENTORY_URL}/resources`),
      fetchJSON(`${REPORT_URL}/costs`)
    ]);
    const elapsed = Date.now() - start;
    res.json({
      inventory,
      reports,
      elapsed_ms: elapsed,
      cached: false
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.listen(8000, () => console.log('API Gateway running on :8000'));
