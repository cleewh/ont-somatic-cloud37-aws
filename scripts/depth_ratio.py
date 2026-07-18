#!/usr/bin/env python3
"""Analyze the tumor mosdepth depth distribution (col4 = mean depth per window)
to extract the depth RATIO that drives ClairS full-alignment cost, then combine
with the measured per-candidate cost ratio to estimate p (cost ~ depth^p).

NOTE: this QC track uses 50kb windows which DILUTE sharp centromeric/satellite
peaks, so the max/percentile depths here are a LOWER BOUND on the true 500bp-window
depth ratio that the split actually sees. We report p at several depth ratios and
flag the dilution direction.
"""
import gzip, statistics, math, sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tumor_qc_depth.bed.gz"
depths = []
with gzip.open(path, "rt") as f:
    for line in f:
        p = line.rstrip("\n").split("\t")
        if len(p) >= 4:
            try:
                d = float(p[3])
            except ValueError:
                continue
            depths.append((d, p[0], int(p[1]), int(p[2])))

vals = sorted(d for d, *_ in depths)
n = len(vals)
def pct(q):
    i = min(n-1, int(q*n))
    return vals[i]

median = statistics.median(vals)
# robust "typical" depth = median of windows with depth>5 (exclude gaps/telomeres)
nonzero = [v for v in vals if v > 5]
med_nz = statistics.median(nonzero)

print(f"windows: {n}  (50kb QC track, tumor)")
print(f"depth percentiles: p50={pct(0.50):.0f}  p90={pct(0.90):.0f}  p99={pct(0.99):.0f}  "
      f"p99.9={pct(0.999):.0f}  MAX={vals[-1]:.0f}")
print(f"median(all)={median:.0f}  median(depth>5)={med_nz:.0f}")

# top 8 deepest windows and where they are
depths.sort(reverse=True)
print("\ndeepest windows (contig, start, mean_depth):")
for d, c, s, e in depths[:8]:
    print(f"   {c}:{s}-{e}   depth={d:.0f}")

# p estimate: cost_ratio measured from cloud25 eval logs
COST_RATIO = 14500.0   # 0.004 -> 58.56 s/candidate
print(f"\nmeasured per-candidate cost ratio (cloud25 eval logs): {COST_RATIO:.0f}x")
print("p = log(cost_ratio)/log(depth_ratio) for candidate depth ratios:")
typ = med_nz
for label, dmax in [("QC-max(50kb,diluted)", vals[-1]),
                    ("QC-p99.9", pct(0.999)),
                    ("2x dilution corr.", vals[-1]*2),
                    ("4x dilution corr.", vals[-1]*4)]:
    dr = dmax/typ
    if dr > 1:
        p = math.log(COST_RATIO)/math.log(dr)
        print(f"   d_deep={dmax:7.0f}  d_typ={typ:5.0f}  ratio={dr:6.1f}x ({label:22s}) -> p={p:.2f}")
