#!/usr/bin/env python3
"""Paginated status for the cloud26 run: stage progress + eval shard counts."""
import json, subprocess, sys, collections

RUN = sys.argv[1] if len(sys.argv) > 1 else "8384814"
tasks, token = [], None
while True:
    cmd = ["aws","omics","list-run-tasks","--id",RUN,"--region","ap-southeast-1",
           "--max-results","100","--output","json"]
    if token: cmd += ["--starting-token", token]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if not out.stdout.strip(): break
    j = json.loads(out.stdout)
    tasks += j.get("items", [])
    token = j.get("nextToken")
    if not token: break

print(f"total tasks: {len(tasks)}")
print("overall status:", dict(collections.Counter(t["status"] for t in tasks)))

def stage(sub):
    st = [t for t in tasks if sub in t["name"]]
    c = collections.Counter(t["status"] for t in st)
    return len(st), dict(c)

for s in ["merge_tumor","ingress_merged","mosdepth_split_depth","split_candidates_by_depth",
          "pileup_variants","evaluate_candidates","aggregate_full_align"]:
    n, c = stage(s)
    if n: print(f"  {s:32s} {n:5d}  {c}")

# a few currently running names
runningfg = [t["name"][:55] for t in tasks if t["status"] == "RUNNING"]
print("running now (sample):", runningfg[:8])
