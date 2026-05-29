// stub_inventory.js — Inventory stub Exp 3
// Latencia: Normal(90 ms, σ=15), recortada a [65, 130] ms
const express = require('express');

function normalRandom(mean, std) {
  // Box-Muller transform
  let u = 0, v = 0;
  while (u === 0) u = Math.random();
  while (v === 0) v = Math.random();
  return mean + std * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

function clamp(val, min, max) {
  return Math.max(min, Math.min(max, val));
}

const app = express();

app.get('/resources', (req, res) => {
  const latency = Math.round(clamp(normalRandom(90, 15), 65, 130));
  setTimeout(() => {
    const resources = Array.from({ length: 20 }, (_, i) => ({
      id: i + 1,
      name: `resource-${i + 1}`,
      type: ['EC2', 'S3', 'RDS', 'Lambda'][i % 4],
      status: 'active',
      region: ['us-east-1', 'us-west-2', 'eu-west-1'][i % 3],
      cost_usd: parseFloat((Math.random() * 100).toFixed(2))
    }));
    res.json({ resources, count: 20, stub_latency_ms: latency });
  }, latency);
});

app.listen(8001, () => console.log('[EXP3] Inventory stub corriendo en :8001  (Normal 90ms σ=15)'));
