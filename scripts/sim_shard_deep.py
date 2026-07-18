#!/usr/bin/env python3
"""Does the cloud26 self-tuning split hold up for DIFFERENT and DEEPER samples?

Uses the MEASURED constants from cloud25 (not assumptions):
  - per-candidate ClairS full-alignment cost = min(c_cand * depth^p, CEIL)   [seconds]
      c_cand = 1.197e-11, p = 2.61  (regression, R^2=0.885)
      CEIL   = 60 s   (MEASURED single-candidate saturation ceiling: 552 n=1 shards,
                       p99=58.6s, max=59.0s -> Clair3/ClairS caps the tensor read stack)
  - split weights each candidate by depth^PW (PW=2.5) and cuts at Sum(w) >= budget OR
    count >= cap. cloud26 budget = T_target / k  (k=3.603e-11 s per unit Sum(d^2.5)).

Robustness question: across shallow->very-deep samples with varying satellite intensity,
does MAX shard time stay ~T_target and does the worst SINGLE candidate stay bounded?
"""
import random, statistics
random.seed(11)

CONTIGS = {'chr1':248,'chr2':242,'chr3':198,'chr4':190,'chr5':181,'chr6':170,'chr7':159,
 'chr8':145,'chr9':138,'chr10':134,'chr11':135,'chr12':133,'chr13':114,'chr14':107,
 'chr15':102,'chr16':90,'chr17':83,'chr18':80,'chr19':59,'chr20':64,'chr21':47,
 'chr22':51,'chrX':156,'chrY':57}

C_CAND = 1.197e-11
P      = 2.61
CEIL   = 60.0          # measured saturation ceiling (s)
PW     = 2.5           # split weight exponent
K      = 3.603e-11     # s per unit Sum(d^2.5), calibrated from cloud25
T_TARGET_S = 300.0     # 5-min mean target (keeps p90/max <= ~10min given CV~0.5)
CAP    = 2000
OVERHEAD_S = 0.0       # ClairS-time only (container overhead handled by HealthOmics scheduling)

def cost_s(d):
    return min(C_CAND * d**P, CEIL)

def gen(base, sat_lo, sat_hi, sat_density_per_mb, sat_span_mb, norm_density=40, jitter_frac=0.15):
    """base = genome-wide diploid depth; satellite peaks near each centromere."""
    g = {}
    for c, L in CONTIGS.items():
        cand = []
        for _ in range(int(L * norm_density)):
            d = max(1, random.gauss(base, base*jitter_frac))
            cand.append((random.uniform(0, L), d))
        cm = 0.45 * L
        for _ in range(int(sat_span_mb * sat_density_per_mb)):
            cand.append((random.uniform(cm-sat_span_mb/2, cm+sat_span_mb/2),
                         random.uniform(sat_lo, sat_hi)))
        cand.sort(); g[c] = cand
    return g

# saturation depth: where c_cand*d^p hits the CEIL (weight should not grow past here)
D_SAT = (CEIL / C_CAND) ** (1.0/P)
WEIGHT_CAP = False   # toggled below

def split(cands, budget):
    shards=[]; acc=0.0; cc=0; cur=[]
    for pos,d in cands:
        w = (min(d, D_SAT) if WEIGHT_CAP else d) ** PW
        cur.append(d); acc += w; cc += 1
        if acc >= budget or cc >= CAP:
            shards.append(cur); cur=[]; acc=0.0; cc=0
    if cur: shards.append(cur)
    return shards

def shard_time_s(shard):
    return OVERHEAD_S + sum(cost_s(d) for d in shard)

def run(g):
    W = sum(d**PW for cc in g for _,d in g[cc])
    budget = T_TARGET_S / K                     # per-shard weight budget for ~T_target
    shards=[]
    for cc in g.values(): shards += split(cc, budget)
    times = sorted(shard_time_s(s) for s in shards)
    n = len(times)
    max_single = max(cost_s(d) for cc in g for _,d in g[cc])
    return n, times, W, budget, max_single

scen = [
 ("30x shallow",                 gen(30,  150,  800,  400, 3)),
 ("60x standard (COLO829-like)", gen(60,  300, 3000,  800, 3)),
 ("90x deep",                    gen(90,  500, 8000, 1000, 3)),
 ("120x very deep",              gen(120, 800,20000, 1200, 4)),
 ("150x ultra-deep",             gen(150,1000,40000, 1500, 4)),
 ("200x extreme + huge sat",     gen(200,2000,90000, 2000, 5)),
 ("60x MASSIVE centromere",      gen(60, 1000,60000, 3000, 6)),
 ("bimodal 40x + heavy amp",     gen(40, 3000,50000, 2500, 4)),
]

import sys
globals_mod = sys.modules[__name__]
print(f"constants: c_cand={C_CAND:.3e}  p={P}  CEIL={CEIL:.0f}s (measured saturation)  "
      f"weight d^{PW}  k={K:.3e}  T_target={T_TARGET_S/60:.0f}min  cap={CAP}  D_SAT~{D_SAT:.0f}x\n")
for wc in [False, True]:
    setattr(globals_mod, "WEIGHT_CAP", wc)
    print(f"=== WEIGHT_CAP={wc} ({'weight=min(d,D_SAT)^2.5' if wc else 'weight=d^2.5'}) ===")
    print("%-30s %8s %7s %7s %7s %8s %10s"%("scenario","shards","p50s","p90s","MAXs","MAX/p90","worst1cand"))
    for lbl,g in scen:
        n,t,W,budget,ms = run(g)
        print("%-30s %8d %7.0f %7.0f %7.0f %8.2f %9.1fs"%(
            lbl, n, t[len(t)//2], t[int(len(t)*0.9)], t[-1], t[-1]/t[int(len(t)*0.9)], ms))
    print()

print("\nInterpretation:")
print("  - MAXs should stay near T_target and MAX/p90 near 1 across ALL depths -> no straggler.")
print("  - shards scales UP with depth (more real work); that's correct, cost scales with workload.")
print("  - worst1cand <= CEIL (60s) ALWAYS -> the smallest indivisible unit is bounded,")
print("    so no depth profile can create an un-splittable multi-hour straggler.")
