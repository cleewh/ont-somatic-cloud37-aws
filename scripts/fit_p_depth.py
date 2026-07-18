#!/usr/bin/env python3
"""Fit p (per-candidate ClairS full-alignment cost ~ depth^p) using the algorithm's
OWN d^2 budget cut to infer each shard's local depth, then regress.

For a shard cut by the depth budget (Sum d^2 = B) with n candidates of ~uniform local
depth d:   n * d^2 ~= B  =>  d = sqrt(B/n).
Per-candidate cost = T_clairs / n.  Model: cost = c * d^p.
   log(T/n) = log c + p * log d       (slope of this regression = p, directly)

We restrict to shards that plausibly hit the BUDGET (not the cap): n in [1, CAP).
Cap-cut shards (n == CAP) are excluded (their depth is unknown, <= sqrt(B/CAP)).
We also drop the n==1 points from the SLOPE fit (a single candidate may EXCEED
budget, so sqrt(B/1) under-estimates its true depth) but report them separately.
"""
import json, subprocess, re, sys, math, statistics
from concurrent.futures import ThreadPoolExecutor

RUN = sys.argv[1] if len(sys.argv) > 1 else "9960545"
NSAMPLE = int(sys.argv[2]) if len(sys.argv) > 2 else 800
CAP = 2000
B = 3_000_000_000

d = json.load(open(f"/tmp/eval_{RUN}.json"))
comp = [t["taskId"] for t in d if t["status"] == "COMPLETED"]
step = max(1, len(comp) // NSAMPLE)
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
            return (m.group(1), int(m.group(2)), float(el.group(1)))
    except Exception:
        return None
    return None

rows = []
with ThreadPoolExecutor(max_workers=16) as ex:
    for r in ex.map(pull, sample):
        if r:
            rows.append(r)
print(f"parsed {len(rows)} shard logs (run {RUN})")

# budget-cut population for the fit: 2 <= n < CAP (drop n==1 from slope, keep for report)
fit = [(n, t) for c, n, t in rows if 2 <= n < CAP and t > 0]
one = [(n, t) for c, n, t in rows if n == 1 and t > 0]
cap = [(n, t) for c, n, t in rows if n >= CAP and t > 0]

def regress(pairs):
    xs = [math.log(math.sqrt(B/n)) for n, t in pairs]      # log depth
    ys = [math.log(t/n) for n, t in pairs]                 # log per-candidate cost
    mx = statistics.mean(xs); my = statistics.mean(ys)
    s = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sum((x-mx)**2 for x in xs)
    a = my - s*mx
    ss_res = sum((y-(a+s*x))**2 for x, y in zip(xs, ys))
    ss_tot = sum((y-my)**2 for y in ys)
    r2 = 1 - ss_res/ss_tot if ss_tot > 0 else 0
    return s, a, r2

print(f"\ncap-cut shards (n=={CAP}): {len(cap)}   n==1 shards: {len(one)}   "
      f"budget-cut fit shards (2<=n<{CAP}): {len(fit)}")

if len(fit) >= 8:
    p, a, r2 = regress(fit)
    print(f"\n=== FIT: log(cost/cand) vs log(depth=sqrt(B/n)) ===")
    print(f"    p (slope) = {p:.2f}   intercept(log c) = {a:.3f}   c = {math.exp(a):.3e}   R^2 = {r2:.3f}")
    # binned means to show the trend cleanly
    print("\n    binned by candidate count (implied depth), mean per-candidate cost:")
    bins = [(2,10),(10,50),(50,150),(150,400),(400,900),(900,1999)]
    for lo, hi in bins:
        sub = [(n, t) for n, t in fit if lo <= n < hi]
        if sub:
            dmean = statistics.mean([math.sqrt(B/n) for n, t in sub])
            cmean = statistics.mean([t/n for n, t in sub])
            print(f"      n[{lo:>4},{hi:>4}) : depth~{dmean:7.0f}x  cost/cand={cmean:.4f}s  (n_shards={len(sub)})")

if one:
    dm = math.sqrt(B/1)
    cm = statistics.mean([t for n, t in one])
    print(f"\n    n==1 shards: depth>= {dm:.0f}x (budget-limited)  mean T={cm:.1f}s  ({len(one)} shards)")

# cross-check endpoints
allrows = [(n, t) for c, n, t in rows if t > 0 and n > 0]
spc = [t/n for n, t in allrows]
print(f"\ncross-check per-candidate cost ratio: {max(spc)/min(spc):.0f}x")
