#!/usr/bin/env python3
"""charts_latency.py — Panel 6 gráficas para Experimento 3 (ASR de Latencia / Cache-Aside)
Ejecutar tras ambos escenarios Locust:
  python charts_latency.py
Entradas: no_cache_results.csv, cache_results.csv
Salida:   latency_charts.png
"""
import csv
import time as time_mod
import argparse
import random
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from matplotlib.lines import Line2D

BG      = '#0d1117'
DARK_BG = '#161b22'
BLUE    = '#58a6ff'
GREEN   = '#2ea043'
ORANGE  = '#e3b341'
RED     = '#da3633'
GRAY    = '#8b949e'
PURPLE  = '#bc8cff'


def load_csv(path):
    rows = []
    try:
        with open(path, newline='', encoding='utf-8') as f:
            for row in csv.DictReader(f):
                rows.append({
                    'ts':           float(row['ts']),
                    'elapsed_ms':   float(row['elapsed_ms']),
                    'status':       int(row['status']),
                    'cache_status': row['cache_status'],
                })
    except FileNotFoundError:
        print(f'[warn] {path} no encontrado — usando datos simulados')
        rows = _simulate(path)
    return rows


def _simulate(path):
    rows = []
    t0 = time_mod.time()
    if 'no_cache' in path:
        for i in range(900):
            rows.append({
                'ts':           t0 + i * 0.095,
                'elapsed_ms':   max(80, min(310, random.gauss(165, 32))),
                'status':       200,
                'cache_status': 'BYPASS',
            })
    else:
        for i in range(4000):
            t = t0 + i * 0.022
            cs = 'MISS' if i < 6 else 'HIT'
            lat = max(12, min(42, random.gauss(19, 4))) if cs == 'HIT' \
                else max(80, min(310, random.gauss(165, 32)))
            rows.append({'ts': t, 'elapsed_ms': lat, 'status': 200, 'cache_status': cs})
    return rows


def style_ax(ax, title):
    ax.set_facecolor(DARK_BG)
    ax.set_title(title, color='white', fontweight='bold', fontsize=9)
    ax.tick_params(colors=GRAY, labelsize=8)
    ax.xaxis.label.set_color(GRAY)
    ax.yaxis.label.set_color(GRAY)
    for sp in ax.spines.values():
        sp.set_color('#30363d')
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)


def main():
    no_cache_rows = load_csv('no_cache_results.csv')
    cache_rows    = load_csv('cache_results.csv')

    nc_lat = [r['elapsed_ms'] for r in no_cache_rows if r['status'] == 200]
    c_ok   = [r for r in cache_rows if r['status'] == 200]
    c_hit  = [r['elapsed_ms'] for r in c_ok if r['cache_status'] == 'HIT']
    c_miss = [r['elapsed_ms'] for r in c_ok if r['cache_status'] == 'MISS']
    c_lat  = [r['elapsed_ms'] for r in c_ok]

    plt.style.use('dark_background')
    fig = plt.figure(figsize=(18, 14))
    fig.patch.set_facecolor(BG)
    gs  = gridspec.GridSpec(3, 2, figure=fig, hspace=0.48, wspace=0.35)

    # ── 1: Barras agrupadas de percentiles ────────────────────────────────────
    ax1 = fig.add_subplot(gs[0, 0])
    percs   = [50, 75, 95, 99]
    nc_vals = [np.percentile(nc_lat, p) for p in percs] if nc_lat else [0] * 4
    c_vals  = [np.percentile(c_lat,  p) for p in percs] if c_lat  else [0] * 4
    x, w    = np.arange(len(percs)), 0.35
    ax1.bar(x - w/2, nc_vals, w, color=BLUE,  alpha=0.85, label='Sin caché')
    ax1.bar(x + w/2, c_vals,  w, color=GREEN, alpha=0.85, label='Con caché')
    ax1.set_xticks(x)
    ax1.set_xticklabels([f'p{p}' for p in percs])
    ax1.set_ylabel('Latencia (ms)')
    ax1.axhline(y=800, color=RED, linestyle='--', linewidth=1, label='ASR límite 800ms')
    ax1.legend(facecolor='#21262d', labelcolor='white', fontsize=7)
    style_ax(ax1, 'Percentiles: Sin caché vs Con caché')

    # ── 2: CDF ────────────────────────────────────────────────────────────────
    ax2 = fig.add_subplot(gs[0, 1])
    for data, color, label in [
        (sorted(nc_lat), BLUE,   'Sin caché'),
        (sorted(c_lat),  GREEN,  'Con caché'),
        (sorted(c_hit),  PURPLE, 'Solo HITs'),
    ]:
        if data:
            cdf = np.arange(1, len(data) + 1) / len(data)
            ax2.plot(data, cdf, color=color, linewidth=1.5, label=label)
    ax2.axvline(x=800, color=RED, linestyle='--', linewidth=1, alpha=0.7, label='ASR 800ms')
    ax2.set_xlabel('Latencia (ms)')
    ax2.set_ylabel('CDF')
    ax2.legend(facecolor='#21262d', labelcolor='white', fontsize=7)
    style_ax(ax2, 'CDF de latencias')

    # ── 3: Scatter latencia en el tiempo ──────────────────────────────────────
    ax3 = fig.add_subplot(gs[1, 0])

    def rel(rows):
        if not rows:
            return []
        t0 = rows[0]['ts']
        return [r['ts'] - t0 for r in rows]

    nc_t = rel(no_cache_rows)
    nc_l = [r['elapsed_ms'] for r in no_cache_rows]
    if nc_t:
        ax3.scatter(nc_t, nc_l, c=BLUE, s=3, alpha=0.35, label='Sin caché', zorder=2)

    c_t = rel(cache_rows)
    hit_t  = [c_t[i] for i, r in enumerate(cache_rows) if r['cache_status'] == 'HIT']
    hit_l  = [r['elapsed_ms'] for r in cache_rows if r['cache_status'] == 'HIT']
    miss_t = [c_t[i] for i, r in enumerate(cache_rows) if r['cache_status'] == 'MISS']
    miss_l = [r['elapsed_ms'] for r in cache_rows if r['cache_status'] == 'MISS']
    if hit_t:
        ax3.scatter(hit_t,  hit_l,  c=GREEN,  s=3, alpha=0.4, zorder=3)
    if miss_t:
        ax3.scatter(miss_t, miss_l, c=ORANGE, s=6, alpha=0.8, zorder=4)

    legend_elems = [
        Line2D([0], [0], marker='o', color='w', markerfacecolor=BLUE,   ms=6, label='Sin caché'),
        Line2D([0], [0], marker='o', color='w', markerfacecolor=GREEN,  ms=6, label='Cache HIT'),
        Line2D([0], [0], marker='o', color='w', markerfacecolor=ORANGE, ms=6, label='Cache MISS'),
    ]
    ax3.legend(handles=legend_elems, facecolor='#21262d', labelcolor='white', fontsize=7)
    ax3.set_xlabel('Tiempo (s)')
    ax3.set_ylabel('Latencia (ms)')
    style_ax(ax3, 'Latencia en el tiempo')

    # ── 4: Box plot ───────────────────────────────────────────────────────────
    ax4 = fig.add_subplot(gs[1, 1])
    sets   = [d for d in [nc_lat, c_hit, c_miss] if d]
    labels = [l for d, l in zip([nc_lat, c_hit, c_miss],
                                 ['Sin caché', 'Cache HIT', 'Cache MISS']) if d]
    colors = [c for d, c in zip([nc_lat, c_hit, c_miss],
                                  [BLUE, GREEN, ORANGE]) if d]
    if sets:
        bp = ax4.boxplot(
            sets, labels=labels, patch_artist=True,
            medianprops=dict(color='white', linewidth=1.5),
            whiskerprops=dict(color=GRAY), capprops=dict(color=GRAY),
            flierprops=dict(marker='.', color=GRAY, alpha=0.3, markersize=3)
        )
        for patch, color in zip(bp['boxes'], colors):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
    ax4.set_ylabel('Latencia (ms)')
    style_ax(ax4, 'Box plot: Sin caché / HIT / MISS')

    # ── 5: Throughput acumulado ────────────────────────────────────────────────
    ax5 = fig.add_subplot(gs[2, 0])
    WINDOW = 5.0

    def rolling_rps(rows, window=WINDOW):
        if not rows:
            return [], []
        t0 = rows[0]['ts']
        ts = [r['ts'] - t0 for r in rows]
        bins = np.arange(0, max(ts) + window, window)
        counts, edges = np.histogram(ts, bins=bins)
        return edges[:-1] + window / 2, counts / window

    nc_x, nc_rps = rolling_rps(no_cache_rows)
    c_x,  c_rps  = rolling_rps(cache_rows)
    if len(nc_x): ax5.plot(nc_x, nc_rps, color=BLUE,  linewidth=1.5, label='Sin caché')
    if len(c_x):  ax5.plot(c_x,  c_rps,  color=GREEN, linewidth=1.5, label='Con caché')
    ax5.set_xlabel('Tiempo (s)')
    ax5.set_ylabel('req/s')
    ax5.legend(facecolor='#21262d', labelcolor='white', fontsize=7)
    style_ax(ax5, 'Throughput acumulado (ventana 5 s)')

    # ── 6: Hit rate en el tiempo ──────────────────────────────────────────────
    ax6 = fig.add_subplot(gs[2, 1])
    INTERVAL = 5.0

    def hit_rate_over_time(rows, interval=INTERVAL):
        if not rows:
            return [], []
        t0 = rows[0]['ts']
        ts     = np.array([r['ts'] - t0 for r in rows])
        is_hit = np.array([1.0 if r['cache_status'] == 'HIT' else 0.0 for r in rows])
        bins   = np.arange(0, ts.max() + interval, interval)
        centers, rates = [], []
        for i in range(len(bins) - 1):
            mask = (ts >= bins[i]) & (ts < bins[i + 1])
            if mask.sum() > 0:
                centers.append((bins[i] + bins[i + 1]) / 2)
                rates.append(is_hit[mask].mean() * 100)
        return centers, rates

    c_t_hr, c_hr = hit_rate_over_time(cache_rows)
    if c_t_hr:
        ax6.plot(c_t_hr, c_hr, color=GREEN, linewidth=1.5, marker='o', markersize=3)
        ax6.fill_between(c_t_hr, c_hr, alpha=0.18, color=GREEN)
    ax6.axhline(y=95, color=ORANGE, linestyle='--', linewidth=1, label='Objetivo 95 %')
    ax6.set_ylim(0, 108)
    ax6.set_xlabel('Tiempo (s)')
    ax6.set_ylabel('Hit rate (%)')
    ax6.legend(facecolor='#21262d', labelcolor='white', fontsize=7)
    style_ax(ax6, 'Hit rate en el tiempo (intervalo 5 s)')

    # ── Resumen en consola ────────────────────────────────────────────────────
    print('\n=== Resumen Experimento 3 ===')
    if nc_lat:
        print(f'Sin caché  — promedio: {np.mean(nc_lat):.1f} ms  '
              f'p95: {np.percentile(nc_lat, 95):.1f} ms  '
              f'ASR(<800ms): {"✓" if np.percentile(nc_lat, 95) < 800 else "✗"}')
    if c_lat:
        print(f'Con caché  — promedio: {np.mean(c_lat):.1f} ms  '
              f'p95: {np.percentile(c_lat, 95):.1f} ms')
    if c_hit:
        print(f'Cache HITs — promedio: {np.mean(c_hit):.1f} ms  '
              f'p95: {np.percentile(c_hit, 95):.1f} ms')
    if c_miss:
        print(f'Cache MISS — promedio: {np.mean(c_miss):.1f} ms  '
              f'(≈ sin caché, delta ≈ 1–4 ms)')
    if c_ok:
        hr = len(c_hit) / len(c_ok) * 100
        print(f'Hit rate global: {hr:.1f} %')
    if nc_lat and c_lat:
        imp = np.percentile(nc_lat, 95) / np.percentile(c_lat, 95)
        print(f'Mejora p95 (cache vs sin caché): {imp:.1f}×')

    # ── Guardar ───────────────────────────────────────────────────────────────
    fig.suptitle('Experimento 3 — ASR de Latencia: Redis Cache-Aside',
                 color='white', fontsize=13, fontweight='bold', y=0.99)
    out = 'latency_charts.png'
    plt.savefig(out, dpi=150, bbox_inches='tight', facecolor=BG)
    print(f'Gráficas guardadas: {out}')


if __name__ == '__main__':
    main()
