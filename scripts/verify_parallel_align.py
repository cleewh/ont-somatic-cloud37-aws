#!/usr/bin/env python3
"""Verify cloud31 uBAM alignments ran in parallel and merge_tumor waited for both tumors."""
import json, sys
from datetime import datetime

def parse(ts):
    if not ts:
        return None
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))

with open("/tmp/cloud31_tasks.json") as f:
    tasks = json.load(f)

def overlap(a, b):
    # a,b = (start,stop) datetimes; treat missing stop as "still running" (open interval)
    s = max(a[0], b[0])
    e_a = a[1] or datetime.max.replace(tzinfo=a[0].tzinfo)
    e_b = b[1] or datetime.max.replace(tzinfo=b[0].tzinfo)
    e = min(e_a, e_b)
    return (e - s).total_seconds()

# Identify alignment-related tasks (minimap2 / ingress / align)
keys = ("minimap2", "ingress", "align", "mosdepth", "merge_tumor", "check_for_alignment", "bam2fq")
rows = []
for t in tasks:
    nm = (t.get("name") or "")
    low = nm.lower()
    if any(k in low for k in keys):
        rows.append(t)

rows.sort(key=lambda t: t.get("start") or t.get("create") or "")
print(f"{'TASK':45s} {'STATUS':10s} {'CPU':>3s} {'START(UTC)':20s} {'STOP(UTC)':20s} {'DUR(min)':>8s}")
print("-" * 120)
aligns = []
merge = None
for t in rows:
    st = parse(t.get("start"))
    sp = parse(t.get("stop"))
    dur = f"{(sp-st).total_seconds()/60:.1f}" if (st and sp) else "running" if st else "-"
    ss = t.get("start","")[:19] if t.get("start") else "-"
    pp = t.get("stop","")[:19] if t.get("stop") else "-"
    print(f"{t.get('name','')[:45]:45s} {t.get('status',''):10s} {str(t.get('cpus','')):>3s} {ss:20s} {pp:20s} {dur:>8s}")
    low = t.get("name","").lower()
    if "merge_tumor" in low:
        merge = t
    elif st and ("minimap2" in low or "ingress" in low or "align" in low or "bam2fq" in low):
        aligns.append(t)

print("\n=== PARALLELISM CHECK ===")
# Pairwise overlap among the earliest alignment tasks
started = [t for t in aligns if parse(t.get("start"))]
started.sort(key=lambda t: t.get("start"))
if len(started) >= 2:
    for i in range(len(started)):
        for j in range(i+1, len(started)):
            a = (parse(started[i]["start"]), parse(started[i].get("stop")))
            b = (parse(started[j]["start"]), parse(started[j].get("stop")))
            ov = overlap(a, b)
            if ov > 0:
                print(f"OVERLAP {ov/60:6.1f} min : {started[i]['name'][:40]}  ||  {started[j]['name'][:40]}")
else:
    print("Fewer than 2 alignment tasks started so far.")

if merge:
    ms = parse(merge.get("start"))
    print(f"\nmerge_tumor start: {merge.get('start')}  status={merge.get('status')}")
    if ms:
        for t in started:
            sp = parse(t.get("stop"))
            flag = "OK (align done before merge)" if (sp and sp <= ms) else "!! merge started before this align stopped" if sp else "align still running"
            print(f"  vs {t['name'][:40]:40s} stop={t.get('stop')}  -> {flag}")
    else:
        print("  merge_tumor not started yet.")
else:
    print("\nmerge_tumor: not present in task list yet.")
