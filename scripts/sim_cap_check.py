#!/usr/bin/env python3
"""Confirm raising the shallow cap 2000->20000 (cloud27) reduces shard count WITHOUT
reintroducing stragglers, using the measured cost model (cost=min(c*d^p,60s))."""
import random, statistics
random.seed(3)
C_CAND=1.197e-11; P=2.61; CEIL=60.0; PW=2.5; K=3.603e-11; T=300.0
# per-candidate cost has a DEPTH-INDEPENDENT FLOOR (~0.006s, measured: cloud26 shallow
# shards ran ~32s = ~20s overhead + 2000*~0.006s) plus the depth term, capped at the 60s
# saturation ceiling. cost = clamp(floor + c*d^p, floor, CEIL).
CFLOOR=0.006
BUDGET=T/K  # per-shard weight budget (~8.33e12)

CONTIGS={'chr1':248,'chr2':242,'chr3':198,'chr4':190,'chr5':181,'chr6':170,'chr7':159,
 'chr8':145,'chr9':138,'chr10':134,'chr11':135,'chr12':133,'chr13':114,'chr14':107,
 'chr15':102,'chr16':90,'chr17':83,'chr18':80,'chr19':59,'chr20':64,'chr21':47,
 'chr22':51,'chrX':156,'chrY':57}
def cost(d): return min(CFLOOR + C_CAND*d**P, CEIL)
def gen():  # ~60x COLO829-like + centromere satellite
    g={}
    for c,L in CONTIGS.items():
        cand=[(random.uniform(0,L), max(1,random.gauss(60,9))) for _ in range(int(L*3000))]
        cm=0.45*L
        cand += [(random.uniform(cm-1.5,cm+1.5), random.uniform(300,3000)) for _ in range(int(3*4000))]
        cand.sort(); g[c]=cand
    return g
def run(cap):
    g=gen(); OVER=20.0  # ~20s per-shard container/staging overhead (measured)
    shards=[]
    for cc in g.values():
        acc=0.0; n=0; cur=[]
        for _,d in cc:
            w=min(d,73438)**PW; cur.append(d); acc+=w; n+=1
            if acc>=BUDGET or n>=cap: shards.append(cur); cur=[]; acc=0; n=0
        if cur: shards.append(cur)
    times=sorted(OVER+sum(cost(d) for d in s) for s in shards)
    n=len(times); billed=sum(max(t,60) for t in times); actual=sum(times)
    print(f"cap={cap:>6}: shards={n:5d}  p50={times[n//2]:5.0f}s  max={times[-1]:5.0f}s  "
          f"<60s={100*sum(1 for t in times if t<60)/n:3.0f}%  "
          f"billed_hr={billed/3600:5.1f}  actual_hr={actual/3600:5.1f}  floor_tax=+{100*(billed-actual)/actual:.0f}%")
for cap in [2000, 10000, 20000, 50000]:
    run(cap)
