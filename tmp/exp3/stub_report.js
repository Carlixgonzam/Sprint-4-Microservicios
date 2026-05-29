// stub_report.js — Report stub Exp 3
// Latencia: Normal(110 ms, σ=18), recortada a [80, 160] ms
const express = require('express');

function normalRandom(mean, std) {
  let u = 0, v = 0;
  while (u === 0) u = Math.random();
  while (v === 0) v = Math.random();
  return mean + std * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

function clamp(val, min, max) {
  return Math.max(min, Math.min(max, val));
}

const app = express();

app.get('/costs', (req, res) => {
  const latency = Math.round(clamp(normalRandom(110, 18), 80, 160));
  setTimeout(() => {
    const docs = Array.from({ length: 10 }, (_, i) => ({
      id: i + 1,
      period: `2025-${String(i + 1).padStart(2, '0')}`,
      total_usd: parseFloat((Math.random() * 500 + 100).toFixed(2)),
      services: Math.floor(Math.random() * 5) + 3,
      breakdown: { compute: 40, storage: 30, network: 20, other: 10 }
    }));
    res.json({ reports: docs, count: 10, stub_latency_ms: latency });
  }, latency);
});

app.listen(8002, () => console.log('[EXP3] Report stub corriendo en :8002  (Normal 110ms σ=18)'));
