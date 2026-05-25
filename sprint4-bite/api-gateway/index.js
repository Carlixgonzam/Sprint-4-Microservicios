const express = require('express');
const rateLimit = require('express-rate-limit');
const { createProxyMiddleware } = require('http-proxy-middleware');
const jwt = require('jsonwebtoken');
const morgan = require('morgan');
const http = require('http');

const app = express();
app.use(morgan('combined'));
app.use(express.json());

const JWT_SECRET = process.env.JWT_SECRET || 'bite-secret-2025';

const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  handler: (req, res) => {
    console.log(`[AUDIT] BLOCKED ${req.ip} - ${new Date().toISOString()} - ${req.path}`);
    res.status(429).json({
      error: 'Too Many Requests',
      message: 'Rate limit exceeded. Blocked automatically.',
      ip: req.ip,
      timestamp: new Date().toISOString()
    });
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
    console.log(`[AUDIT] INVALID_TOKEN ${req.ip} - ${new Date().toISOString()}`);
    return res.status(403).json({ error: 'Invalid token' });
  }
}

app.post('/auth/token', (req, res) => {
  const { username } = req.body;
  if (!username) return res.status(400).json({ error: 'username required' });
  const token = jwt.sign({ username, iat: Date.now() }, JWT_SECRET, { expiresIn: '24h' });
  res.json({ token });
});

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'api-gateway' }));

const INVENTORY_URL = process.env.INVENTORY_URL || 'http://localhost:8001';
const REPORT_URL = process.env.REPORT_URL || 'http://localhost:8002';
const NOTIF_URL = process.env.NOTIF_URL || 'http://localhost:8003';

app.use('/inventory', verifyToken, createProxyMiddleware({
  target: INVENTORY_URL, changeOrigin: true,
  pathRewrite: { '^/inventory': '' }
}));

app.use('/reports', verifyToken, createProxyMiddleware({
  target: REPORT_URL, changeOrigin: true,
  pathRewrite: { '^/reports': '' }
}));

app.use('/notifications', verifyToken, createProxyMiddleware({
  target: NOTIF_URL, changeOrigin: true,
  pathRewrite: { '^/notifications': '' }
}));

function fetchJSON(url) {
  return new Promise((resolve, reject) => {
    http.get(url, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch(e) { reject(e); }
      });
    }).on('error', reject);
  });
}

app.get('/dashboard/summary', verifyToken, async (req, res) => {
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
