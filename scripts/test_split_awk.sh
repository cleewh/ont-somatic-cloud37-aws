#!/bin/bash
set -e
cd /tmp
# synthetic per-contig depth windows: chr20 tiled 50kb; middle window is ultra-deep
printf 'chr20\t0\t50000\t30\nchr20\t50000\t100000\t1000\nchr20\t100000\t150000\t30\n' > d.bed
# candidates: 3 shallow (win1), 6 deep (win2), 3 shallow (win3)
: > c.bed
for p in 1000 2000 3000; do printf 'chr20\t%d\t%d\n' $p $((p+100)) >> c.bed; done
for p in 60000 65000 70000 75000 80000 85000; do printf 'chr20\t%d\t%d\n' $p $((p+100)) >> c.bed; done
for p in 110000 120000 130000; do printf 'chr20\t%d\t%d\n' $p $((p+100)) >> c.bed; done
sort -k1,1 -k2,2n c.bed > c.sorted.bed
# budget: 30^2=900 (shallow), 1000^2=1,000,000 (deep). Budget=2,000,000 -> deep window
# candidates (each ~1e6 weight) split ~every 2 candidates; shallow (900) never trips alone.
mkdir -p dsplit; rm -f dsplit/*
B=2000000
awk -v B=$B '
BEGIN { FS=OFS="\t"; acc=0; i=0; n=0; j=0 }
FNR==NR { ws[++n]=$2+0; we[n]=$3+0; wd[n]=$4+0; next }
{
    s=$2+0; e=$3+0
    while (j < n && we[j+1] <= s) j++
    sum=0; cnt=0; k=j+1
    while (k <= n && ws[k] < e) { if (we[k] > s) { sum+=wd[k]; cnt++ }; k++ }
    d = (cnt>0) ? sum/cnt : 1
    if (d < 1) d = 1
    print $0 >> (sprintf("dsplit/part.%05d.bed", i))
    acc += d*d
    if (acc >= B) { i++; acc=0 }
}' d.bed c.sorted.bed
echo "=== input candidates: $(wc -l < c.sorted.bed) ==="
echo "=== shards produced ==="
for f in dsplit/part.*.bed; do echo "$f: $(wc -l < $f) lines"; done
echo "=== total lines out (must equal input) ==="
cat dsplit/part.*.bed | wc -l
