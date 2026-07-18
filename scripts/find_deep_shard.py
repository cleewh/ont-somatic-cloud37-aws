#!/usr/bin/env python3
"""Find the eval shard with the highest per-candidate ClairS cost and dump its full log
to inspect what fields (coordinates/coverage) are available."""
import json, subprocess, re, sys
from concurrent.futures import ThreadPoolExecutor

RUN = sys.argv[1] if len(sys.argv) > 1 else "9960545"
d = json.load(open(f"/tmp/eval_{RUN}.json"))
comp = [t["taskId"] for t in d if t["status"] == "COMPLETED"]
step = max(1, len(comp) // 500)
sample = comp[::step]

def pull(tid):
    try:
        out = subprocess.run(
            ["aws", "logs", "get-log-events", "--log-group-name", "/aws/omics/WorkflowLog",
             "--log-stream-name", f"run/{RUN}/task/{tid}", "--region", "ap-southeast-1",
             "--start-from-head", "--output", "json"],
            capture_output=True, text=True, timeout=60)
        j = json.loads(out.stdout)
        msgs = " ".join(e["message"] for e in j.get("events", []))
        m = re.search(r"processed positions in (\S+)\s*:\s*(\d+)", msgs)
        el = re.search(r"Total time elapsed:\s*([\d.]+)\s*s", msgs)
        if m and el and int(m.group(2)) > 0:
            return (float(el.group(1))/int(m.group(2)), tid, m.group(1), int(m.group(2)), float(el.group(1)), msgs)
    except Exception:
        return None
    return None

rows = []
with ThreadPoolExecutor(max_workers=16) as ex:
    for r in ex.map(pull, sample):
        if r:
            rows.append(r)

rows.sort()
print("=== 3 cheapest per-candidate shards ===")
for spc, tid, ctg, n, t, _ in rows[:3]:
    print(f"  tid={tid} {ctg} n={n} T={t}s s/cand={spc:.5f}")
print("=== 3 most expensive per-candidate shards ===")
for spc, tid, ctg, n, t, _ in rows[-3:]:
    print(f"  tid={tid} {ctg} n={n} T={t}s s/cand={spc:.5f}")
print("\n=== FULL LOG of most expensive shard ===")
print(rows[-1][5])
