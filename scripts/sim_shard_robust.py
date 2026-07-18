#!/usr/bin/env python3
"""
Robustness test for the time-targeted depth-aware split.
Tests across MANY depth profiles AND against the unknown true cost exponent p_cost,
while the split weights by d^p_weight (default 2). Straggler = MAX shard time >> p90.
"""
import random, statistics
random.seed(7)

CONTIGS = {c:l for c,l in {
 'chr1':248,'chr2':242,'chr3':198,'chr4':190,'chr5':181,'chr6':170,'chr7':159,
 'chr8':145,'chr9':138,'chr10':134,'chr11':135,'chr12':133,'chr13':114,'chr14':107,
 'chr15':102,'chr16':90,'chr17':83,'chr18':80,'chr19':59,'chr20':64,'chr21':47,
 'chr22':51,'chrX':156,'chrY':57}.items()}

def gen(base, spike_lo, spike_hi, deep_density, deep_mb, norm_density=40, jitter=8):
    g={}
    for c,L in CONTIGS.items():
        cand=[]
        for _ in range(int(L*norm_density)):
            cand.append((random.uniform(0,L), max(1,random.gauss(base,jitter))))
        cm=0.4*L
        for _ in range(int(deep_mb*deep_density)):
            cand.append((random.uniform(cm-deep_mb/2,cm+deep_mb/2), random.uniform(spike_lo,spike_hi)))
        cand.sort(); g[c]=cand
    return g

def split(cands, budget, cap, pw):
    shards=[];acc=0.0;cc=0;cur=[]
    for pos,d in cands:
        cur.append((pos,d)); acc+=d**pw; cc+=1
        if acc>=budget or cc>=cap: shards.append(cur);cur=[];acc=0.0;cc=0
    if cur: shards.append(cur)
    return shards

def shard_time_min(shard, p_cost, c, overhead=20.0):
    return (overhead + c*sum(d**p_cost for _,d in shard))/60.0

def run(g, N_target, pw, p_cost, c, cap=2000):
    # time-targeted: budget = W_total(weight)/N
    W = sum(d**pw for cc in g for _,d in g[cc])
    budget = W/N_target
    shards=[]
    for cc in g.values(): shards += split(cc, budget, cap, pw)
    times=sorted(shard_time_min(s,p_cost,c) for s in shards)
    return len(shards), times

# scenarios: (label, genome)
scen = [
 ("30x shallow uniform",      gen(30, 150, 800, 1500, 3)),
 ("60x standard (COLO829)",   gen(60, 300, 2500, 3000, 3)),
 ("90x deep",                 gen(90, 500, 3500, 3500, 3)),
 ("120x very deep",           gen(120, 800, 5000, 4000, 3)),
 ("60x MASSIVE centromere",   gen(60, 1000, 6000, 8000, 5)),
 ("60x low-complexity (few spikes)", gen(60, 200, 600, 400, 2)),
 ("bimodal 40x+heavy",        gen(40, 2000, 8000, 5000, 4)),
]

# We CALIBRATE N so a d^2-weighted, d^2-cost run hits ~10min max on the 60x standard,
# then reuse the SAME per-sample rule (N=W2*c/T) everywhere. Derive c from a target.
# Assume from real data: a shard with sum(d^2)=B2 takes ~ c*B2 sec. Pick c so 60x std ~10min at N=300.
g60 = dict(scen[1][1])
W2_60 = sum(d**2 for cc in g60 for _,d in g60[cc])
T_target_min = 10.0
# choose c so that budget(=W2_60/300) * c = T_target*60  -> c = T*60/(W2_60/300)
c = (T_target_min*60)/(W2_60/300)
print(f"calibration: W2(60x)={W2_60:,.0f}  c={c:.3e}  (tuned so 60x std ~{T_target_min}min)\n")

print("=== A) time-targeted budget=W2*c/T (pw=2, p_cost=2)  -> should hold ~T across ALL depths ===")
print("%-34s %7s %8s %8s %8s %8s"%("scenario","shards","p50","p90","MAX","MAX/p90"))
for lbl,g in scen:
    W2=sum(d**2 for cc in g for _,d in g[cc]); N=int(W2*c/(T_target_min*60))
    N=max(N,len(CONTIGS))
    n,t=run(g,N,2,2,c)
    print("%-34s %7d %8.1f %8.1f %8.1f %8.2f"%(lbl,n,t[len(t)//2],t[int(len(t)*0.9)],t[-1],t[-1]/t[int(len(t)*0.9)]))

print("\n=== B) EXPONENT-MISMATCH robustness: weight by d^2 but TRUE cost is d^p_cost ===")
print("(same 60x std sample, N tuned for 10min at p_cost=2; straggler if MAX/p90 large)")
print("%-14s %7s %8s %8s %8s %8s"%("true p_cost","shards","p50","p90","MAX","MAX/p90"))
for p_cost in [1.0,1.5,2.0,2.5,3.0]:
    W2=sum(d**2 for cc in g60 for _,d in g60[cc]); N=300
    # recompute c for THIS p_cost so p50~10min (fair compare of SHAPE not absolute)
    # keep same c as calibrated; just observe shape
    n,t=run(g60,N,2,p_cost,c)
    print("%-14.1f %7d %8.1f %8.1f %8.1f %8.2f"%(p_cost,n,t[len(t)//2],t[int(len(t)*0.9)],t[-1],t[-1]/t[int(len(t)*0.9)]))

print("\n=== C) FIX: match weight exponent to cost. weight d^p_cost, cost d^p_cost -> balanced? ===")
print("%-14s %7s %8s %8s %8s %8s"%("p (w=cost)","shards","p50","p90","MAX","MAX/p90"))
for p in [1.5,2.0,2.5,3.0]:
    Wp=sum(d**p for cc in g60 for _,d in g60[cc]); N=300
    cc2=(T_target_min*60)/(Wp/N)
    n,t=run(g60,N,p,p,cc2)
    print("%-14.1f %7d %8.1f %8.1f %8.1f %8.2f"%(p,n,t[len(t)//2],t[int(len(t)*0.9)],t[-1],t[-1]/t[int(len(t)*0.9)]))


print("\n=== D) SWEEP many c (unknown per-candidate cost coeff): does N=W2*c/T keep MAX~T? ===")
print("For each c we recompute N from the SAME rule N=round(W2*c/T); check max shard time vs T=%.0fmin"%T_target_min)
print("%-12s %8s %8s %8s %8s %8s"%("c","N","p50","p90","MAX","MAX/T"))
W2_std=sum(d**2 for cc in g60 for _,d in g60[cc])
for c_test in [1e-9,1e-8,3e-8,1e-7,3e-7,1e-6,1e-5]:
    N=int(W2_std*c_test/(T_target_min*60)); N=max(N,len(CONTIGS))
    n,t=run(g60,N,2,2,c_test)
    print("%-12.0e %8d %8.1f %8.1f %8.1f %8.2f"%(c_test,n,t[len(t)//2],t[int(len(t)*0.9)],t[-1],t[-1]/T_target_min))

print("\n=== E) c-sweep ACROSS depth profiles (same N-rule): MAX shard time should stay ~T everywhere ===")
print("%-30s %-10s %6s %7s %7s"%("scenario","c","N","MAX","MAX/T"))
for lbl,g in scen:
    W2=sum(d**2 for cc in g for _,d in g[cc])
    for c_test in [1e-8,1e-7,1e-6]:
        N=int(W2*c_test/(T_target_min*60)); N=max(N,len(CONTIGS))
        n,t=run(g,N,2,2,c_test)
        print("%-30s %-10.0e %6d %7.1f %7.2f"%(lbl[:30],c_test,n,t[-1],t[-1]/T_target_min))
