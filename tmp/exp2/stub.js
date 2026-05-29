// stub.js — Microservicios stub para Experimento 2
// Un solo proceso que levanta dos servidores Express: puerto 8001 (inventory) y 8002 (reports)
const express = require('express');

function randInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

// ── Inventory stub :8001 ────────────────────────────────────────────────────
const inventory = express();

inventory.get('/resources', (req, res) => {
  setTimeout(() => {
    const resources = Array.from({ length: 20 }, (_, i) => ({
      id: i + 1,
      name: `resource-${i + 1}`,
      type: ['EC2', 'S3', 'RDS', 'Lambda'][i % 4],
      status: 'active',
      region: ['us-east-1', 'us-west-2', 'eu-west-1'][i % 3],
      cost_usd: parseFloat((Math.random() * 100).toFixed(2))
    }));
    res.json({ resources, count: 20 });
  }, randInt(40, 80));
});

inventory.listen(8001, () => console.log('[EXP2] Inventory stub corriendo en :8001'));

// ── Report stub :8002 ───────────────────────────────────────────────────────
const reports = express();

reports.get('/costs', (req, res) => {
  setTimeout(() => {
    const docs = Array.from({ length: 10 }, (_, i) => ({
      id: i + 1,
      period: `2025-${String(i + 1).padStart(2, '0')}`,
      total_usd: parseFloat((Math.random() * 500 + 100).toFixed(2)),
      services: randInt(3, 8)
    }));
    res.json({ reports: docs, count: 10 });
  }, randInt(50, 90));
});

reports.listen(8002, () => console.log('[EXP2] Report stub corriendo en :8002'));
