#!/usr/bin/env python3
"""Quantify evaluate_candidates over-billing: how many shards run < 60s (billed at the
1-min HealthOmics floor) and the billed/actual ratio. Compares cloud26 vs cloud25."""
import json, sys, datetime, statistics

def analyze(run):
    d = json.load(open(f"/tmp/eval_{run}.json"))
    now = datetime.datetime.now(datetime.timezone.utc)
    durs = []
    for t in d:
        if t["status"] != "COMPLETED": continue
        s = t.get("start")
        if not s: continue
        e = datetime.datetime.fromisoformat(t["stop"]) if t.get("stop") else now
        durs.append((e - datetime.datetime.fromisoformat(s)).total_seconds())
    durs.sort()
    n = len(durs)
    if n == 0:
        print(f"{run}: no completed eval tasks in /tmp/eval_{run}.json"); return
    under60 = sum(1 for x in durs if x < 60)
    actual = sum(durs)
    billed = sum(max(x, 60) for x in durs)
    print(f"=== run {run}: {n} eval shards ===")
    print(f"  duration: p50={durs[n//2]:.0f}s p90={durs[int(n*0.9)]:.0f}s max={durs[-1]:.0f}s")
    print(f"  shards <60s (billed at 1-min floor): {under60} ({100*under60/n:.0f}%)")
    print(f"  actual task-hours={actual/3600:.1f}  billed task-hours={billed/3600:.1f}  "
          f"floor tax=+{100*(billed-actual)/actual:.0f}%")

for r in sys.argv[1:] or ["8384814"]:
    analyze(r)
