#!/usr/bin/env python3
"""Per-contig depth distribution from the tumor mosdepth track (50kb windows).
Shows what depth the FAST-phasing contigs actually have vs chr1's deep centromere,
to pick the right phasing depth cap. (50kb dilutes peaks -> real 500bp peaks higher,
but relative per-contig comparison holds.)"""
import gzip, collections, statistics

path = "/tmp/tumor_qc_depth.bed.gz"
by = collections.defaultdict(list)
with gzip.open(path, "rt") as f:
    for line in f:
        p = line.split("\t")
        if len(p) >= 4:
            try: d = float(p[3])
            except: continue
            by[p[0]].append(d)

def pct(v, q):
    v = sorted(v); return v[min(len(v)-1, int(q*len(v)))]

order = [f"chr{i}" for i in range(1,23)] + ["chrX","chrY"]
print("%-7s %8s %7s %8s %9s %10s" % ("contig","windows","p50","p99","p99.9","MAX"))
for c in order:
    if c not in by: continue
    v = by[c]
    print("%-7s %8d %7.0f %8.0f %9.0f %10.0f" % (
        c, len(v), pct(v,0.5), pct(v,0.99), pct(v,0.999), max(v)))

# summary: fast contigs (all except chr1) max window depth
allc = {c: max(v) for c,v in by.items() if c in order}
nonchr1 = {c:m for c,m in allc.items() if c != "chr1"}
print("\nchr1 MAX window (50kb): %.0f" % allc.get("chr1", -1))
print("non-chr1 contigs MAX window: max=%.0f  median-of-maxes=%.0f" % (
    max(nonchr1.values()), statistics.median(list(nonchr1.values()))))
print("non-chr1 contigs with MAX>1000x:", sorted([c for c,m in nonchr1.items() if m>1000]))
print("non-chr1 contigs with MAX>5000x:", sorted([c for c,m in nonchr1.items() if m>5000]))
