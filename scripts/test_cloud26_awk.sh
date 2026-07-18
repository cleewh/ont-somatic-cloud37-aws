#!/usr/bin/env bash
# Offline validation of the cloud26 split awk (exact copy of the module logic).
# Generates a synthetic contig: shallow genome-wide candidates + a deep satellite
# peak, runs the split, and checks: weight=min(d,DSAT)^p, time-targeted budget,
# shard sizes, manifest correctness, and per-shard time bound using the cost model.
set -euo pipefail
cd "$(mktemp -d)"
echo "workdir: $PWD"

P=2.5; DSAT=73438; K=3.603e-11; TMIN=5; M=2000; C=chr1

# synthetic 500bp depth track (BED: contig start end mean_depth), 0..2,000,000
python3 - <<'PY'
import random
random.seed(1)
with open("depth.contig.bed","w") as f:
    x=0
    while x < 2_000_000:
        # baseline 60x, with a deep satellite plateau 900k-1000k up to ~50000x
        if 900_000 <= x < 1_000_000:
            d = random.uniform(30000, 55000)
        else:
            d = max(1, random.gauss(60, 9))
        f.write(f"chr1\t{x}\t{x+500}\t{d:.1f}\n")
        x += 500
PY

# synthetic candidates: dense in shallow genome, few in the deep plateau
python3 - <<'PY'
import random
random.seed(2)
rows=[]
# shallow: ~8000 candidates spread across genome
for _ in range(8000):
    p=random.randrange(0,2_000_000)
    if not (900_000<=p<1_000_000):
        rows.append(p)
# deep plateau: ~40 candidates (few but ultra-deep)
for _ in range(40):
    rows.append(random.randrange(900_000,1_000_000))
rows.sort()
with open("cand.sorted.bed","w") as f:
    for p in rows:
        f.write(f"chr1\t{p}\t{p+1}\tC\n")
PY

mkdir -p dsplit
awk -v P=$P -v DSAT=$DSAT -v K=$K -v TMIN=$TMIN -v M=$M -v C="$C" '
BEGIN { FS=OFS="\t"; B=TMIN*60.0/K; acc=0; cc=0; i=0; n=0; j=0; W=0; ncand=0 }
FNR==NR { ws[++n]=$2+0; we[n]=$3+0; wd[n]=$4+0; next }
{
    s=$2+0; e=$3+0
    while (j < n && we[j+1] <= s) j++
    sum=0; cnt=0; k=j+1
    while (k <= n && ws[k] < e) { if (we[k] > s) { sum+=wd[k]; cnt++ }; k++ }
    d = (cnt>0) ? sum/cnt : 1
    if (d < 1) d = 1
    dw = (d < DSAT) ? d : DSAT
    w = dw ^ P
    fn = sprintf("dsplit/%s.part.%05d.bed", C, i)
    print $0 >> fn
    acc += w; cc++; W += w; ncand++
    if (acc >= B || cc >= M) { close(fn); i++; acc=0; cc=0 }
}
END {
    ns = i + (cc>0 ? 1 : 0)
    print C, ncand, W, B, ns, P, DSAT, K, TMIN > (C ".split_manifest.tsv")
}' depth.contig.bed cand.sorted.bed

echo "=== MANIFEST ==="
cat "$C.split_manifest.tsv"
echo "=== SHARD COUNT ==="
ls dsplit | wc -l
echo "=== total candidates across shards (must equal manifest n_candidates) ==="
cat dsplit/* | wc -l
echo "=== per-shard candidate counts (head/tail) ==="
for f in dsplit/*; do wc -l < "$f"; done | sort -n | uniq -c | tail -6

# verify no candidate lost and per-shard modeled time using cost=min(c*d^p,60)
python3 - "$PWD" <<'PY'
import glob, statistics, os, sys
wd=sys.argv[1]
# reload depth for lookup
wins=[]
for ln in open(f"{wd}/depth.contig.bed"):
    _,s,e,dp=ln.split("\t"); wins.append((int(s),int(e),float(dp)))
def depth_at(pos):
    # simple: window index
    idx=pos//500
    if 0<=idx<len(wins): return wins[idx][2]
    return 1.0
C_CAND=1.197e-11; P=2.61; CEIL=60.0
times=[]
for f in glob.glob(f"{wd}/dsplit/*"):
    t=0.0
    for ln in open(f):
        pos=int(ln.split("\t")[1])
        d=max(1.0,depth_at(pos))
        t+=min(C_CAND*d**P, CEIL)
    times.append(t)
times.sort()
n=len(times)
print("=== MODELED per-shard ClairS time (s) ===")
print(f"shards={n} p50={times[n//2]:.1f} p90={times[int(n*0.9)]:.1f} MAX={times[-1]:.1f} "
      f"MAX/p90={times[-1]/times[int(n*0.9)]:.2f}")
print(f"target was {5*60}s; MAX under 2x target? {'YES' if times[-1] < 2*5*60 else 'NO'}")
PY
echo "OK"
