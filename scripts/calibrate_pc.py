#!/usr/bin/env python3
"""Consolidated p + c calibration for cloud26 from cloud25 (run 9960545) eval logs
+ the tumor mosdepth depth track. Writes results to scripts/pc_calibration.json.

Findings model:
  per-candidate ClairS full-alignment cost = c_cand * depth^p   (seconds)
Two independent views:
  (1) DEEP-RANGE regression over budget-cut shards (depth inferred = sqrt(B/n)):
        log(T/n) = log c_cand + p*log(sqrt(B/n))   -> slope p
  (2) FULL-RANGE endpoints (shallow cap shards at measured median depth vs the
        deepest satellite candidate) -> effective exponent; LOWER because the
        extreme tail SATURATES (Clair3/ClairS caps tensor read stack).
For the cloud26 SHARD-TIME budget we calibrate directly in shard-time units:
  T_shard = k * Sum(d^p)   over the shard's candidates.
Using the budget-cut invariant Sum(d^2)=B and uniform-d approx d=sqrt(B/n):
  Sum(d^p) = n * (B/n)^(p/2) = B^(p/2) * n^(1 - p/2)
  => k = T_shard / (B^(p/2) * n^(1-p/2))
Then cloud26 target budget in Sum(d^p) units:  W_budget = T_target / k.
"""
import json, subprocess, re, sys, math, statistics
from concurrent.futures import ThreadPoolExecutor

RUN = "9960545"
CAP = 2000
B = 3_000_000_000
NSAMPLE = 800

d = json.load(open(f"/tmp/eval_{RUN}.json"))
comp = [t["taskId"] for t in d if t["status"] == "COMPLETED"]
step = max(1, len(comp)//NSAMPLE)
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

rows = [r for r in ThreadPoolExecutor(max_workers=16).map(pull, sample) if r]
print(f"parsed {len(rows)} shard logs")

# (1) deep-range regression -> p
fit = [(n, t) for c, n, t in rows if 2 <= n < CAP and t > 0]
xs = [0.5*math.log(B/n) for n, t in fit]
ys = [math.log(t/n) for n, t in fit]
mx, my = statistics.mean(xs), statistics.mean(ys)
p = sum((x-mx)*(y-my) for x, y in zip(xs, ys))/sum((x-mx)**2 for x in xs)
logc = my - p*mx
ss_res = sum((y-(logc+p*x))**2 for x, y in zip(xs, ys)); ss_tot = sum((y-my)**2 for y in ys)
r2 = 1 - ss_res/ss_tot
c_cand = math.exp(logc)
print(f"(1) DEEP-RANGE: p={p:.2f}  R^2={r2:.3f}  c_cand={c_cand:.3e} s at depth=1x  (n={len(fit)})")

# (2) shard-time coefficient k for a chosen weight exponent pw (use p_round)
for pw in [2.0, 2.5, round(p,1)]:
    ks = [ (t) / ( (B**(pw/2)) * (n**(1-pw/2)) ) for n, t in fit ]
    kmed = statistics.median(ks)
    cv = statistics.pstdev(ks)/statistics.mean(ks)
    Tt = 600.0  # 10 min target
    Wbud = Tt / kmed
    print(f"(2) weight d^{pw}:  k_median={kmed:.3e} s per unit Sum(d^{pw})  (CV={cv:.2f})  "
          f"-> cloud26 W_budget(T=10min)={Wbud:.3e}")

out = {"run": RUN, "p_deeprange": round(p,3), "p_r2": round(r2,3),
       "c_cand_per_depth_p": c_cand, "cap": CAP, "budget_cloud25": B,
       "n_fit_shards": len(fit)}
json.dump(out, open("scripts/pc_calibration.json","w"), indent=2)
print("\nwrote scripts/pc_calibration.json")
