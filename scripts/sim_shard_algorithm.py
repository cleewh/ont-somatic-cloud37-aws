#!/usr/bin/env python3
"""
Simulate depth/candidate distribution and test the ADAPTIVE shard-count algorithm
(budget = W_total / N_target) that cloud26 would use, BEFORE implementing it in Nextflow.

Grounded in observed reality:
- GRCh38 main contigs chr1..22,X,Y (lengths in Mb).
- Merged tumor baseline depth ~60x (2 x 30x).
- Centromeric/satellite windows: sharp depth spikes (200-3000x) at 500bp resolution
  (these are the loci that drove the stragglers).
- Somatic candidates: sparse in normal regions, dense clusters in deep regions.
- eval cost model: time = fixed_overhead + sum_candidates c*depth^p
  (from logs: ~20s fixed overhead/shard; per-candidate cost rises with depth).
"""
import random, statistics, math
random.seed(42)

# GRCh38 primary contig lengths (Mb, approx)
CONTIGS = {
 'chr1':248,'chr2':242,'chr3':198,'chr4':190,'chr5':181,'chr6':170,'chr7':159,
 'chr8':145,'chr9':138,'chr10':134,'chr11':135,'chr12':133,'chr13':114,'chr14':107,
 'chr15':102,'chr16':90,'chr17':83,'chr18':80,'chr19':59,'chr20':64,'chr21':47,
 'chr22':51,'chrX':156,'chrY':57,
}
# approx centromere position (fraction along contig) - deep satellite zone
CENT = {c:0.4 for c in CONTIGS}

BASE_DEPTH = 60          # merged tumor baseline
CAND_PER_MB_NORMAL = 40  # somatic candidate density in normal regions
DEEP_ZONE_MB = 3.0       # width of the deep centromeric zone
DEEP_CAND_PER_MB = 3000  # candidate density explodes in deep satellite regions

def gen_sample(depth_scale=1.0, spike_max=2500):
    """Return {contig: [(pos, depth), ...]} sorted by pos."""
    genome = {}
    for c, length_mb in CONTIGS.items():
        cand = []
        cent_mb = CENT[c]*length_mb
        # normal-region candidates
        n_norm = int(length_mb * CAND_PER_MB_NORMAL)
        for _ in range(n_norm):
            pos = random.uniform(0, length_mb)
            # depth ~ baseline with mild variation
            d = max(1, random.gauss(BASE_DEPTH*depth_scale, 8))
            cand.append((pos, d))
        # deep centromeric-zone candidates (sharp spike)
        n_deep = int(DEEP_ZONE_MB * DEEP_CAND_PER_MB)
        for _ in range(n_deep):
            pos = random.uniform(cent_mb-DEEP_ZONE_MB/2, cent_mb+DEEP_ZONE_MB/2)
            d = random.uniform(300, spike_max)*depth_scale
            cand.append((pos, d))
        cand.sort()
        genome[c] = cand
    return genome

def split_contig(cands, budget, cap):
    """Mirror split_candidates_by_depth: contiguous, cut on Sum(d^2)>=budget OR count>=cap."""
    shards=[]; acc=0.0; cc=0; cur=[]
    for pos,d in cands:
        cur.append((pos,d)); acc += d*d; cc+=1
        if acc>=budget or cc>=cap:
            shards.append(cur); cur=[]; acc=0.0; cc=0
    if cur: shards.append(cur)
    return shards

def eval_time_min(shard, overhead_s=20.0, c=0.00003, p=2.0):
    """Estimated eval runtime for a shard (min). per-candidate cost c*d^p."""
    work_s = sum(c*(d**p) for pos,d in shard)
    return (overhead_s + work_s)/60.0

def analyze(genome, N_target, cap=2000, label=""):
    W_total = sum(d*d for c in genome for pos,d in genome[c])
    budget = W_total / N_target
    all_shards=[]; per_contig={}
    for c,cands in genome.items():
        sh = split_contig(cands, budget, cap)
        per_contig[c]=len(sh); all_shards += sh
    times = sorted(eval_time_min(s) for s in all_shards)
    ncand = sum(len(genome[c]) for c in genome)
    print(f"=== {label}  N_target={N_target}, cap={cap} ===")
    print(f"  total candidates: {ncand:,}   W_total(sum d^2): {W_total:,.0f}   budget: {budget:,.0f}")
    print(f"  ACTUAL shards: {len(all_shards)}  (target {N_target}, +~1/contig rounding; {len(CONTIGS)} contigs)")
    print(f"  shard eval time min:  p50 {times[len(times)//2]:.1f}  p90 {times[int(len(times)*0.9)]:.1f}  MAX {times[-1]:.1f}")
    print(f"  min shard time: {times[0]:.2f}   (straggler if MAX >> p90)")
    return len(all_shards), times[-1], W_total

print("### TEST 1: does budget=W_total/N give ~N shards? sweep N ###")
g = gen_sample()
for N in [100, 200, 300, 500, 1000]:
    analyze(g, N, label=f"sample A (60x)")
    print()

print("### TEST 2: adaptivity - a DEEPER sample (90x, higher spikes) at same N_target=300 ###")
g2 = gen_sample(depth_scale=1.5, spike_max=3500)
analyze(g2, 300, label="sample B (90x, deeper)")
print()

print("### TEST 3: contrast - OLD fixed-budget on both samples (shows why it's unpredictable) ###")
for lbl,gg in [("A 60x",g),("B 90x",gg2 if False else g2)]:
    W=sum(d*d for c in gg for pos,d in gg[c])
    for fixed_budget in [400_000_000, 3_000_000_000]:
        sh=[]
        for c,cands in gg.items(): sh+=split_contig(cands, fixed_budget, 2000)
        print(f"  {lbl}: fixed budget {fixed_budget:,} -> {len(sh)} shards (W_total={W:,.0f})")
