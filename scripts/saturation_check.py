#!/usr/bin/env python3
"""Test whether single-candidate ClairS full-alignment cost SATURATES at extreme depth.
If it does, the worst indivisible unit (one candidate) has a BOUNDED time regardless of
how deep a sample is -> the split is robust to arbitrarily deep samples.

We collect ALL sampled n==1 and n==2 shards (each is 1-2 of the DEEPEST candidates in the
genome, since only ultra-deep candidates hit the d^2 budget with so few candidates) and
look at the distribution of their ClairS 'Total time elapsed'. Clustering near a ceiling
= saturation. A long exploding tail = NO saturation (danger for deeper samples)."""
import json, subprocess, re, statistics
from concurrent.futures import ThreadPoolExecutor

RUN = "9960545"
d = json.load(open(f"/tmp/eval_{RUN}.json"))
comp = [t["taskId"] for t in d if t["status"] == "COMPLETED"]
# large sample to catch many deep singletons
step = max(1, len(comp)//2500)
sample = comp[::step]

def pull(tid):
    try:
        out = subprocess.run(["aws","logs","get-log-events","--log-group-name","/aws/omics/WorkflowLog",
            "--log-stream-name",f"run/{RUN}/task/{tid}","--region","ap-southeast-1",
            "--start-from-head","--output","json"], capture_output=True, text=True, timeout=60)
        j = json.loads(out.stdout); msgs = " ".join(e["message"] for e in j.get("events", []))
        m = re.search(r"processed positions in (\S+)\s*:\s*(\d+)", msgs)
        el = re.search(r"Total time elapsed:\s*([\d.]+)\s*s", msgs)
        if m and el and int(m.group(2)) > 0:
            return (m.group(1), int(m.group(2)), float(el.group(1)))
    except Exception:
        return None

rows = [r for r in ThreadPoolExecutor(max_workers=24).map(pull, sample) if r]
print(f"parsed {len(rows)} shard logs (large sample for deep-tail)")

def summ(name, ts):
    if not ts: 
        print(f"{name}: none"); return
    ts = sorted(ts)
    n = len(ts)
    print(f"{name} (n={n}): min={ts[0]:.1f}s  p50={ts[n//2]:.1f}s  p90={ts[int(n*0.9)]:.1f}s  "
          f"p99={ts[min(n-1,int(n*0.99))]:.1f}s  MAX={ts[-1]:.1f}s")

# n==1 shards = single deepest candidates
one = [t for c,n,t in rows if n == 1]
two = [t for c,n,t in rows if n == 2]
few = [t for c,n,t in rows if 1 <= n <= 5]
summ("single-candidate (n=1) ClairS time", one)
summ("n=2 shards", two)
summ("n<=5 (deep) shards", few)

# Which contigs produce the deep singletons?
import collections
ctg1 = collections.Counter(c for c,n,t in rows if n == 1)
print("\ncontigs of n=1 (deepest) shards:", dict(ctg1.most_common(8)))

# Saturation verdict: compare cost of a single candidate implied by d^2.6 extrapolation
# vs observed. If observed MAX single-candidate << pure-power extrapolation from the
# regression, cost saturates.
print("\nSATURATION VERDICT:")
if one:
    om = max(one); op90 = sorted(one)[int(len(one)*0.9)]
    print(f"  worst single candidate = {om:.1f}s, p90 = {op90:.1f}s")
    print(f"  spread p90->max = {om/op90:.2f}x  (near 1.0 => tight ceiling => SATURATED)")
    print(f"  pure d^2.6 (c=1.197e-11) at depth 55000x would predict "
          f"{1.197e-11*55000**2.61:.0f}s for ONE candidate; observed max {om:.1f}s.")
