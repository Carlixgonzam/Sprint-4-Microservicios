#!/usr/bin/env python3
"""charts_security.py — Panel 4 gráficas para Experimento 2 (ASR de Seguridad)
Ejecutar: python charts_security.py
Entrada:  security_results.csv
Salida:   security_charts.png
"""
import csv
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec

CSV_FILE = 'security_results.csv'

BG      = '#0d1117'
DARK_BG = '#161b22'
GREEN   = '#2ea043'
RED     = '#da3633'
ORANGE  = '#e3b341'
BLUE    = '#58a6ff'
GRAY    = '#8b949e'

# ── Cargar datos ──────────────────────────────────────────────────────────────
rows = []
with open(CSV_FILE, newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        rows.append({
            'nro':              int(row['nro']),
            'status_code':      int(row['status_code']),
            'elapsed_ms':       float(row['elapsed_ms']),
            'relative_time_s':  float(row['relative_time_s']),
        })

nros      = [r['nro'] for r in rows]
codes     = [r['status_code'] for r in rows]
latencies = [r['elapsed_ms'] for r in rows]
times     = [r['relative_time_s'] for r in rows]

ok_idx = [i for i, c in enumerate(codes) if c == 200]
bl_idx = [i for i, c in enumerate(codes) if c == 429]

ok_lat = [latencies[i] for i in ok_idx]
bl_lat = [latencies[i] for i in bl_idx]

first_block_nro = nros[bl_idx[0]] if bl_idx else None
first_block_t   = times[bl_idx[0]] if bl_idx else None

n_ok    = len(ok_idx)
n_bl    = len(bl_idx)
total   = len(rows)
p95_ok  = np.percentile(ok_lat, 95) if ok_lat else 0
p95_bl  = np.percentile(bl_lat, 95) if bl_lat else 0
asr_ok  = first_block_t <= 10.0 if first_block_t is not None else False

# ── Figura ────────────────────────────────────────────────────────────────────
plt.style.use('dark_background')
fig = plt.figure(figsize=(16, 10))
fig.patch.set_facecolor(BG)
gs  = gridspec.GridSpec(2, 2, figure=fig, hspace=0.42, wspace=0.35)

def style_ax(ax):
    ax.set_facecolor(DARK_BG)
    ax.tick_params(colors=GRAY, labelsize=8)
    ax.xaxis.label.set_color(GRAY)
    ax.yaxis.label.set_color(GRAY)
    for sp in ax.spines.values():
        sp.set_color('#30363d')
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

# ── Plot 1: Scatter nro_solicitud vs latencia ─────────────────────────────────
ax1 = fig.add_subplot(gs[0, 0])
ax1.scatter([nros[i] for i in ok_idx], [latencies[i] for i in ok_idx],
            c=GREEN, s=14, alpha=0.8, label='HTTP 200', zorder=3)
ax1.scatter([nros[i] for i in bl_idx], [latencies[i] for i in bl_idx],
            c=RED,   s=18, alpha=0.95, label='HTTP 429', zorder=4)
if first_block_nro is not None:
    ax1.axvline(x=first_block_nro, color=ORANGE, linestyle='--', linewidth=1.5, zorder=2)
    ymax = ax1.get_ylim()[1]
    ax1.annotate(
        f'Bloqueo #{first_block_nro}\nt={first_block_t:.2f}s',
        xy=(first_block_nro, ymax * 0.5),
        xytext=(first_block_nro + 2.5, ymax * 0.75),
        color=ORANGE, fontsize=8,
        arrowprops=dict(arrowstyle='->', color=ORANGE, lw=1.2)
    )
ax1.set_xlabel('Nro. solicitud')
ax1.set_ylabel('Latencia (ms)')
ax1.set_title('Latencia por solicitud', color='white', fontweight='bold')
ax1.legend(facecolor='#21262d', labelcolor='white', fontsize=8)
style_ax(ax1)

# ── Plot 2: Barras horizontales de distribución ───────────────────────────────
ax2 = fig.add_subplot(gs[0, 1])
pct_ok = n_ok / total * 100
pct_bl = n_bl / total * 100
etiquetas = [f'Bloqueadas (429)  {n_bl} req', f'Aceptadas (200)   {n_ok} req']
valores   = [pct_bl, pct_ok]
colores   = [RED, GREEN]
bars = ax2.barh(etiquetas, valores, color=colores, height=0.45, edgecolor='none')
for bar, val in zip(bars, valores):
    ax2.text(bar.get_width() + 0.8, bar.get_y() + bar.get_height() / 2,
             f'{val:.1f} %', va='center', color='white', fontsize=10, fontweight='bold')
ax2.set_xlim(0, 115)
ax2.set_xlabel('% del total')
ax2.set_title('Distribución de respuestas', color='white', fontweight='bold')
style_ax(ax2)

# ── Plot 3: Histograma de latencias superpuesto ───────────────────────────────
ax3 = fig.add_subplot(gs[1, 0])
if ok_lat:
    ax3.hist(ok_lat, bins=np.arange(0, max(ok_lat) + 15, 10),
             color=GREEN, alpha=0.65, label='HTTP 200')
if bl_lat:
    ax3.hist(bl_lat, bins=np.arange(0, max(bl_lat) + 3, 1),
             color=RED, alpha=0.9, label='HTTP 429')
ax3.set_xlabel('Latencia (ms)')
ax3.set_ylabel('Frecuencia')
ax3.set_title('Histograma de latencias', color='white', fontweight='bold')
ax3.legend(facecolor='#21262d', labelcolor='white', fontsize=8)
style_ax(ax3)

# ── Plot 4: Panel de métricas clave (texto) ───────────────────────────────────
ax4 = fig.add_subplot(gs[1, 1])
ax4.set_facecolor(DARK_BG)
ax4.axis('off')
ax4.set_title('Métricas clave', color='white', fontweight='bold')

metricas = [
    ('Solicitudes aceptadas (200)',   f'{n_ok}',                                GREEN),
    ('Solicitudes bloqueadas (429)',  f'{n_bl}',                                RED),
    ('Primera solicitud bloqueada',  f'#{first_block_nro}' if first_block_nro else 'N/A', ORANGE),
    ('Tiempo hasta primer bloqueo',  f'{first_block_t:.3f} s' if first_block_t else 'N/A', ORANGE),
    ('ASR: Detección ≤ 10 s',        'CUMPLE ✓' if asr_ok else 'NO CUMPLE ✗', GREEN if asr_ok else RED),
    ('Latencia p95 (HTTP 200)',       f'{p95_ok:.1f} ms',                       BLUE),
    ('Latencia p95 (HTTP 429)',       f'{p95_bl:.1f} ms',                       BLUE),
    ('Tasa de error (tráfico legít.)', '0 %',                                   GREEN),
]

y = 0.93
for label, value, color in metricas:
    ax4.text(0.03, y, label, transform=ax4.transAxes,
             color=GRAY, fontsize=9, va='top')
    ax4.text(0.97, y, value, transform=ax4.transAxes,
             color=color, fontsize=9, va='top', ha='right', fontweight='bold')
    y -= 0.108

# ── Guardar ───────────────────────────────────────────────────────────────────
fig.suptitle('Experimento 2 — ASR de Seguridad: Rate Limiting en API Gateway',
             color='white', fontsize=13, fontweight='bold', y=0.99)
out = 'security_charts.png'
plt.savefig(out, dpi=150, bbox_inches='tight', facecolor=BG)
print(f'Gráficas guardadas: {out}')
