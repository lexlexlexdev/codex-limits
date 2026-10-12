#!/usr/bin/env python3
"""Measure a fresh app launch and its descendants. No credentials or prompts read.

Usage: python3 tools/measure.py [--seconds 60] [--popover]
RSS is sampled every 250 ms; CPU is measured from cumulative process CPU time.
Run with the popover closed for idle results. Requires Python only for measurement.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def cpu_seconds(text):
    minutes, seconds = text.split(":")
    return int(minutes) * 60 + float(seconds)


def snapshot(root):
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time=,comm="], text=True)
    rows = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) == 5:
            pid, parent, rss, cpu, name = parts
            rows[int(pid)] = (int(parent), int(rss), cpu_seconds(cpu), name)
    tree = {root}
    while True:
        children = {pid for pid, row in rows.items() if row[0] in tree}
        if children <= tree:
            break
        tree |= children
    return {pid: rows[pid] for pid in tree if pid in rows}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--popover", action="store_true")
    args = parser.parse_args()
    binary = Path(__file__).resolve().parent.parent / "dist/Codex Limits.app/Contents/MacOS/CodexLimits"
    command = [str(binary)] + (["--show-popover"] if args.popover else [])
    started = time.monotonic()
    child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    peak_app = peak_tree = 0
    process_names = set()
    idle_start = None
    last = None
    observed_cpu = {}
    try:
        while time.monotonic() - started < args.seconds:
            if child.poll() is not None:
                raise RuntimeError("App exited early: " + child.stderr.read().decode())
            rows = snapshot(child.pid)
            if child.pid in rows:
                peak_app = max(peak_app, rows[child.pid][1])
            peak_tree = max(peak_tree, sum(row[1] for row in rows.values()))
            for pid, row in rows.items():
                observed_cpu[pid] = max(observed_cpu.get(pid, 0), row[2])
                process_names.add(row[3])
            elapsed = time.monotonic() - started
            if elapsed >= 10 and idle_start is None:
                idle_start = (elapsed, rows.get(child.pid, (0, 0, 0, ""))[2])
            last = rows
            time.sleep(0.25)
        elapsed = time.monotonic() - started
        app = last[child.pid]
        report = {
            "duration_seconds": round(elapsed, 2),
            "popover": args.popover,
            "app_idle_rss_mib": round(app[1] / 1024, 2),
            "tree_idle_rss_mib": round(sum(row[1] for row in last.values()) / 1024, 2),
            "app_peak_rss_mib": round(peak_app / 1024, 2),
            "tree_peak_rss_mib": round(peak_tree / 1024, 2),
            "app_idle_cpu_percent": round(100 * (app[2] - idle_start[1]) / (elapsed - idle_start[0]), 3) if idle_start else None,
            "tree_observed_cpu_seconds": round(sum(observed_cpu.values()), 3),
            "idle_child_count": len(last) - 1,
            "observed_processes": sorted(process_names),
            "limitations": "Sampled RSS (not physical footprint). Sub-250ms children may be missed. Live authenticated network refresh/login may have higher peaks."
        }
        print(json.dumps(report, indent=2))
    finally:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        diagnostics = child.stderr.read().decode()
        if diagnostics:
            print("App diagnostics:", diagnostics[:6000])


if __name__ == "__main__":
    main()
