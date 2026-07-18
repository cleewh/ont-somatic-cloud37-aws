#!/usr/bin/env python3
"""Self-contained estimate of the ClairS full-alignment cost exponent p (cost ~ depth^p)
from cloud25 eval-shard logs, WITHOUT assuming any depth ratio.

Model: the splitter cuts each shard when Sum(d^2) >= B (budget) OR count >= M (cap=2000).
For a BUDGET-CUT shard filled to Sum(d^2)=B with ~n candidates of local depth d:
    n * d^2 ~= B          =>  d = (B/n)^(1/2)
    T_clairs = n * c * d^p = c * B^(p/2) * n^(1 - p/2)
So over budget-cut shards:   log T = const + (1 - p/2) * log n
    slope s = 1 - p/2   =>   p = 2 * (1 - s)

Cap-cut shards (n == 2000) and tiny contig-end remainders are EXCLUDED because they
do not obey Sum(d^2)=B. We parse candidate count n and ClairS 'Total time elapsed' T
from each shard log, pulled in parallel.
"""
import json, subprocess, re, sys, math, statistics
from concurrent.futures import ThreadPoolExecutor

RUN = sys.argv[1] if len(sys.argv) > 1 else "9960545"
NSAMPLE = int(sys.argv[2]) if len(sys.argv) > 2 else 500
CAP = 2000
B = 3_000_000_000  # clairs_depth_split_budget in cloud25

d = json.load(open(f"/tmp/eval_{RUN}.json"))
comp = [t["taskId"] for t in d if t["status"] == "COMPLETED"]
# even stride sample across all completed shards
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
        if m and el:
            return (m.group(1), int(m.group(2)), float(el.group(1)))
    except Exception:
        return None
    return None

rows = []
with ThreadPoolExecutor(max_workers=16) as ex:
    for r in ex.map(pull, sample):
        if r:
            rows.append(r)

print(f"parsed {len(rows)} shard logs (of {len(sample)} sampled, run {RUN})")
if not rows:
    sys.exit(0)

counts = [n for _, n, _ in rows]
print(f"candidate-count distribution: min {min(counts)}  median {int(statistics.median(counts))}  "
      f"max {max(counts)}   (cap={CAP})")
ncap = sum(1 for n in counts if n >= CAP)
print(f"cap-cut shards (n>={CAP}): {ncap}   budget/remainder shards (n<{CAP}): {len(counts)-ncap}")

# Budget-cut population: exclude cap-cut (n>=CAP) and tiny remainders (n < NMIN).
NMIN = 50
budget = [(c, n, t) for c, n, t in rows if NMIN <= n < CAP and t > 0]
print(f"\nbudget-cut shards used for regression (n in [{NMIN},{CAP})): {len(budget)}")
if len(budget) >= 5:
    xs = [math.log(n) for _, n, t in budget]
    ys = [math.log(t) for _, n, t in budget]
    mx = statistics.mean(xs); my = statistics.mean(ys)
    s = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sum((x-mx)**2 for x in xs)
    a = my - s*mx
    ss_res = sum((y-(a+s*x))**2 for x, y in zip(xs, ys))
    ss_tot = sum((y-my)**2 for y in ys)
    r2 = 1 - ss_res/ss_tot if ss_tot > 0 else 0
    p = 2*(1 - s)
    print(f"log-log slope (log T vs log n)  s = {s:.3f}   (R^2={r2:.3f})")
    print(f"==> p = 2*(1 - s) = {p:.2f}")
    # implied depth per shard from d=(B/n)^0.5, and per-candidate cost check
    print("\nsanity: implied depth d=(B/n)^0.5 and s/candidate for a few budget shards:")
    for c, n, t in sorted(budget, key=lambda r: r[1])[:3] + sorted(budget, key=lambda r: r[1])[-3:]:
        dep = (B/n)**0.5
        print(f"   {c:>6}  n={n:>4}  T={t:6.1f}s  implied_d={dep:7.0f}x  s/cand={t/n:.4f}")

# Also report raw per-candidate cost ratio (the depth-ratio-dependent estimator, for cross-check)
spc = [(t/n) for _, n, t in rows if n > 0 and t > 0]
if len(spc) >= 3:
    print(f"\ncross-check per-candidate cost: min {min(spc):.5f}  max {max(spc):.5f}  RATIO {max(spc)/min(spc):.0f}x")
