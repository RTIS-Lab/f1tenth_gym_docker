#!/usr/bin/env python3
"""Analysis of FastSimplex evaluation runs.

Parses the JSONL event logs written by rtis_safety_runner (one
events.jsonl per run) into per-run summary statistics, aggregates across
runs by (architecture, checkpoint, track), and produces comparison plots.

Usage:
  python3 scripts/analyze_results.py f1tenth_drive/results \
      [--out eval_out] [--no-plots]

Per-run stats: crash count, time-weighted average speed (overall and
per-mode), time-weighted HI-mode %, command-source breakdown, checker
compute/latency stats (incl. MPC early-stop CPU savings).

Only needs the Python stdlib; plots need matplotlib (skipped if missing).
"""

import argparse
import csv
import json
import os
import statistics
import sys
from collections import defaultdict

CONTROL_PERIOD_US = 50_000
MAX_GAP_S = 0.5  # cap integration gaps (sim paused / startup)


def load_events(path):
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip().rstrip(',')
            if not line or line in ('[', ']'):
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round(pct / 100.0 * (len(ordered) - 1))))
    return ordered[idx]


def analyze_run(path):
    events = load_events(path)
    if not events:
        return None

    meta = next((e for e in events if e.get('type') == 'run_metadata'), {})
    t_start = next((e['t_us'] for e in events
                    if e.get('type') == 'episode_start'), events[0]['t_us'])
    t_end = next((e['t_us'] for e in reversed(events)
                  if e.get('type') == 'episode_end'), events[-1]['t_us'])
    duration_s = max((t_end - t_start) / 1e6, 1e-9)

    stats = {
        'run_dir': os.path.basename(os.path.dirname(path)),
        'architecture': meta.get('architecture', ''),
        'checkpoint': meta.get('model_checkpoint', ''),
        'track': meta.get('track', ''),
        'model_file': meta.get('model_file', ''),
        'run_id': meta.get('run_id', ''),
        'duration_s': round(duration_s, 2),
    }

    # ---- crashes ----
    stats['crashes'] = sum(1 for e in events if e.get('type') == 'crash')

    # ---- mode timeline (time-weighted HI %) ----
    mode_events = [(e['t_us'], e['type']) for e in events
                   if e.get('type') in ('switch_hi', 'switch_lo')]
    hi_time = 0.0
    current_mode_hi = False
    prev_t = t_start
    for t_us, etype in mode_events:
        if current_mode_hi:
            hi_time += max(0, t_us - prev_t)
        prev_t = t_us
        current_mode_hi = etype == 'switch_hi'
    if current_mode_hi:
        hi_time += max(0, t_end - prev_t)
    stats['hi_mode_pct'] = round(100.0 * hi_time / (t_end - t_start), 2) \
        if t_end > t_start else 0.0

    # ---- speed and command sources from command events ----
    commands = [e for e in events if e.get('type') == 'command']
    speed_time = {'LO': 0.0, 'HI': 0.0}
    speed_integral = {'LO': 0.0, 'HI': 0.0}
    dist = 0.0
    for i, e in enumerate(commands):
        t_next = commands[i + 1]['t_us'] if i + 1 < len(commands) else t_end
        dt = min(max(0, t_next - e['t_us']) / 1e6, MAX_GAP_S)
        mode = e.get('mode', 'LO')
        speed = e.get('current_speed', 0.0)
        speed_time[mode] = speed_time.get(mode, 0.0) + dt
        speed_integral[mode] = speed_integral.get(mode, 0.0) + speed * dt
        dist += abs(speed) * dt
    total_time = sum(speed_time.values())
    total_integral = sum(speed_integral.values())
    stats['avg_speed'] = round(total_integral / total_time, 3) \
        if total_time else 0.0
    stats['avg_speed_lo'] = round(
        speed_integral['LO'] / speed_time['LO'], 3) if speed_time['LO'] else 0.0
    stats['avg_speed_hi'] = round(
        speed_integral['HI'] / speed_time['HI'], 3) if speed_time['HI'] else 0.0
    stats['distance_m'] = round(dist, 1)

    # command source: last command in each 50 ms control period wins
    by_period = {}
    for e in commands:
        by_period[e['t_us'] // CONTROL_PERIOD_US] = e.get('source', '?')
    source_counts = defaultdict(int)
    for source in by_period.values():
        source_counts[source] += 1
    n_periods = max(1, len(by_period))
    stats['periods'] = len(by_period)
    for source, count in sorted(source_counts.items()):
        stats[f'src_{source}_pct'] = round(100.0 * count / n_periods, 2)

    # ---- checker cycle stats ----
    def cycle_stats(prefix, cycles):
        if not cycles:
            return
        walls = [c['wall_us'] for c in cycles if 'wall_us' in c]
        cpus = [c['cpu_us'] for c in cycles if 'cpu_us' in c]
        stats[f'{prefix}_cycles'] = len(cycles)
        if walls:
            stats[f'{prefix}_wall_mean_ms'] = round(
                sum(walls) / len(walls) / 1000, 3)
            stats[f'{prefix}_wall_p99_ms'] = round(
                percentile(walls, 99) / 1000, 3)
        if cpus:
            stats[f'{prefix}_cpu_total_s'] = round(sum(cpus) / 1e6, 3)

    fb = [e for e in events if e.get('type') == 'fb_cycle']
    cycle_stats('fb', fb)
    if fb:
        stats['fb_safe_pct'] = round(
            100.0 * sum(1 for e in fb if e.get('is_safe')) / len(fb), 2)

    mpc = [e for e in events if e.get('type') == 'mpc_cycle']
    cycle_stats('mpc', mpc)
    if mpc:
        stopped = [e for e in mpc if e.get('early_stopped')]
        completed = [e for e in mpc if not e.get('early_stopped')]
        stats['mpc_early_stop_pct'] = round(100.0 * len(stopped) / len(mpc), 2)
        if stopped:
            stats['mpc_stopped_cpu_mean_ms'] = round(
                sum(e['cpu_us'] for e in stopped) / len(stopped) / 1000, 3)
        if completed:
            stats['mpc_completed_cpu_mean_ms'] = round(
                sum(e['cpu_us'] for e in completed) / len(completed) / 1000, 3)
        # CPU time the early stop saved vs. always solving to completion
        if stopped and completed:
            saved = (stats['mpc_completed_cpu_mean_ms'] -
                     stats['mpc_stopped_cpu_mean_ms']) * len(stopped) / 1000
            stats['mpc_cpu_saved_s'] = round(saved, 3)

    classic = [e for e in events if e.get('type') == 'classic_cycle']
    cycle_stats('classic', classic)
    if classic:
        stats['classic_safe_pct'] = round(
            100.0 * sum(1 for e in classic if e.get('is_safe')) / len(classic),
            2)

    anytime = [e for e in events if e.get('type') == 'anytime_cycle']
    cycle_stats('anytime', anytime)
    if anytime:
        levels = defaultdict(int)
        for e in anytime:
            levels[e.get('level', '?')] += 1
        for level, count in sorted(levels.items()):
            stats[f'anytime_{level}_pct'] = round(
                100.0 * count / len(anytime), 2)

    return stats


def aggregate(runs):
    """Group per-run stats by (architecture, checkpoint, track); average
    numeric fields."""
    groups = defaultdict(list)
    for run in runs:
        key = (run['architecture'], run['checkpoint'], run['track'])
        groups[key].append(run)
    rows = []
    for (arch, checkpoint, track), members in sorted(groups.items()):
        row = {'architecture': arch, 'checkpoint': checkpoint, 'track': track,
               'runs': len(members)}
        numeric_keys = sorted({k for m in members for k, v in m.items()
                               if isinstance(v, (int, float))})
        for key in numeric_keys:
            values = [m[key] for m in members if key in m]
            if values:
                row[f'{key}_mean'] = round(sum(values) / len(values), 3)
                row[f'{key}_std'] = round(statistics.stdev(values), 3) \
                    if len(values) > 1 else 0.0
        row['crashes_total'] = sum(m.get('crashes', 0) for m in members)
        rows.append(row)
    return rows


def write_csv(path, rows):
    if not rows:
        return
    fields = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with open(path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f'wrote {path} ({len(rows)} rows)')


def make_plots(runs, out_dir):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('matplotlib not available, skipping plots', file=sys.stderr)
        return

    def grouped(metric):
        data = defaultdict(list)
        for run in runs:
            if metric in run:
                data[run['architecture']].append(run[metric])
        return data

    def bar_by_arch(metric, title, filename, ylabel):
        data = grouped(metric)
        if not data:
            return
        archs = sorted(data)
        means = [sum(data[a]) / len(data[a]) for a in archs]
        plt.figure(figsize=(7, 4))
        plt.bar(archs, means)
        plt.ylabel(ylabel)
        plt.title(title)
        plt.xticks(rotation=20)
        plt.tight_layout()
        path = os.path.join(out_dir, filename)
        plt.savefig(path, dpi=120)
        plt.close()
        print(f'wrote {path}')

    bar_by_arch('avg_speed', 'Average speed by architecture',
                'speed_vs_architecture.png', 'speed (m/s)')
    bar_by_arch('hi_mode_pct', 'HI-mode time by architecture',
                'himode_vs_architecture.png', 'HI-mode (%)')
    bar_by_arch('crashes', 'Crashes by architecture',
                'crashes_vs_architecture.png', 'crashes per run')
    bar_by_arch('mpc_cpu_total_s', 'MPC checker CPU time by architecture',
                'mpc_cpu_vs_architecture.png', 'total CPU time (s)')

    # speed vs checkpoint, one line per architecture
    by_arch = defaultdict(lambda: defaultdict(list))
    for run in runs:
        if run.get('checkpoint'):
            by_arch[run['architecture']][run['checkpoint']].append(
                run.get('avg_speed', 0.0))
    if by_arch:
        plt.figure(figsize=(7, 4))
        for arch, by_ckpt in sorted(by_arch.items()):
            checkpoints = sorted(by_ckpt)
            means = [sum(by_ckpt[c]) / len(by_ckpt[c]) for c in checkpoints]
            plt.plot(checkpoints, means, marker='o', label=arch)
        plt.ylabel('speed (m/s)')
        plt.xlabel('model checkpoint')
        plt.title('Average speed vs. checkpoint')
        plt.legend()
        plt.tight_layout()
        path = os.path.join(out_dir, 'speed_vs_checkpoint.png')
        plt.savefig(path, dpi=120)
        plt.close()
        print(f'wrote {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results_root',
                        help='directory to search for events.jsonl files '
                             '(e.g. f1tenth_drive/results)')
    parser.add_argument('--out', default='eval_out',
                        help='output directory for CSVs and plots')
    parser.add_argument('--no-plots', action='store_true')
    args = parser.parse_args()

    log_files = []
    for root, _dirs, files in os.walk(args.results_root):
        if 'events.jsonl' in files:
            log_files.append(os.path.join(root, 'events.jsonl'))
    if not log_files:
        sys.exit(f'no events.jsonl files found under {args.results_root}')

    runs = []
    for path in sorted(log_files):
        stats = analyze_run(path)
        if stats:
            runs.append(stats)
            print(f"{stats['run_dir']}: arch={stats['architecture']} "
                  f"speed={stats['avg_speed']} m/s "
                  f"crashes={stats['crashes']} hi={stats['hi_mode_pct']}%")

    os.makedirs(args.out, exist_ok=True)
    write_csv(os.path.join(args.out, 'summary.csv'), runs)
    write_csv(os.path.join(args.out, 'aggregate.csv'), aggregate(runs))
    if not args.no_plots:
        make_plots(runs, args.out)


if __name__ == '__main__':
    main()
