#!/usr/bin/env python3
"""Compare the EXTENT of deep regions (count of deep 50kb windows) per contig, to see
if chr1 (hung) differs from chr4 (fast) by breadth of deep region rather than peak depth."""
import gzip, collections
by = collections.defaultdict(list)
with gzip.open("/tmp/tumor_qc_depth.bed.gz","rt") as f:
    for line in f:
        p=line.split("\t")
        if len(p)>=4:
            try: d=float(p[3])
            except: continue
            by[p[0]].append(d)
order=[f"chr{i}" for i in range(1,23)]+["chrX","chrY"]
print("%-6s %6s %8s %8s %9s %10s %11s"%("contig","wins",">500x",">1000x",">5000x",">10000x",">20000x"))
for c in order:
    if c not in by: continue
    v=by[c]
    def cnt(t): return sum(1 for x in v if x>t)
    print("%-6s %6d %8d %8d %9d %10d %11d"%(c,len(v),cnt(500),cnt(1000),cnt(5000),cnt(10000),cnt(20000)))
