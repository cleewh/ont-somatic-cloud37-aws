#!/usr/bin/env bash
# Offline validation of the cloud27 chunked-phasing script logic (Nextflow ${} resolved,
# bash \$ unescaped). Uses STUB tools to exercise the chunk loop + timeout fallback + concat
# without needing real longphase/bam. Simulates chr1 length 60Mb -> 3 chunks, with the
# 2nd chunk forced to TIME OUT (fallback to unphased).
set -uo pipefail
WD=$(mktemp -d); cd "$WD"
mkdir bin
# ---- stubs ----
cat > bin/awk_len <<'EOF'
EOF
# fai: chr1 length 60,000,000
printf 'chr1\t60000000\t0\t0\t0\n' > test.fai
# input het VCF (gzipped) with a header + sites across the 3 chunks
{ echo '##fileformat=VCFv4.2'; echo '##contig=<ID=chr1,length=60000000>';
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS\n';
  echo -e 'chr1\t1000\t.\tA\tG\t30\tPASS\t.\tGT\t0/1';
  echo -e 'chr1\t25000000\t.\tC\tT\t30\tPASS\t.\tGT\t0/1';
  echo -e 'chr1\t45000000\t.\tG\tA\t30\tPASS\t.\tGT\t0/1'; } > all.plain
gzip -c all.plain > all_in.vcf.gz

# stub bcftools: view -r reg -> filter by POS range; concat -f list -> cat bodies
cat > bin/bcftools <<'EOF'
#!/usr/bin/env bash
cmd=$1; shift
if [ "$cmd" = view ]; then
  reg=""; out=""; inp=""
  while [ $# -gt 0 ]; do case "$1" in -r) reg=$2; shift 2;; -Ov) shift;; -o) out=$2; shift 2;; -Oz) shift;; *) inp=$1; shift;; esac; done
  lo=${reg#*:}; hi=${lo#*-}; lo=${lo%-*}; ctg=${reg%%:*}
  { gzip -dc "$inp" 2>/dev/null || cat "$inp"; } | awk -v c="$ctg" -v lo="$lo" -v hi="$hi" 'BEGIN{FS=OFS="\t"} /^#/{print;next} $1==c && $2>=lo && $2<=hi {print}' > "${out:-/dev/stdout}"
elif [ "$cmd" = concat ]; then
  list=""; out=""
  while [ $# -gt 0 ]; do case "$1" in -f) list=$2; shift 2;; -o) out=$2; shift 2;; -Oz) shift;; *) shift;; esac; done
  : > /tmp/concat_body
  first=1
  while read p; do
    if [ $first = 1 ]; then gzip -dc "$p"; first=0; else gzip -dc "$p" | grep -v '^#'; fi
  done < "$list" | gzip -c > "$out"
fi
EOF
# stub samtools: view -b reg -> touch bam; index -> touch bai
cat > bin/samtools <<'EOF'
#!/usr/bin/env bash
if [ "$1" = view ]; then out=""; for a in "$@"; do :; done; echo "bam" > chunk.bam; 
  # honor > redirect handled by caller; also write to last arg? caller uses > file
  cat /dev/null; fi
if [ "$1" = index ]; then echo "bai" > "${2}.bai" 2>/dev/null || true; fi
EOF
# stub longphase: -o prefix -s chunk.vcf ; 2nd chunk (POS 25M) -> sleep to trigger timeout
cat > bin/longphase <<'EOF'
#!/usr/bin/env bash
pref=""; snp=""
while [ $# -gt 0 ]; do case "$1" in -o) pref=$2; shift 2;; -s) snp=$2; shift 2;; *) shift;; esac; done
# emit a "phased" vcf = input (pretend phased)
if grep -q $'\t25000000\t' "$snp"; then sleep 120; fi   # force timeout on chunk 2
cp "$snp" "$pref.vcf"
EOF
cat > bin/bgzip <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ]; then shift; gzip -c "$1"; elif [ "$1" = "-f" ]; then gzip -f "$2"; else gzip -f "$1"; fi
EOF
cat > bin/tabix <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do f=$a; done; echo idx > "$f.tbi"
EOF
# timeout shim (macOS lacks it): enforce 2s so the sleeping chunk is killed, quick chunks pass
cat > bin/timeout <<'EOF'
#!/usr/bin/env bash
shift            # drop the duration arg (e.g. 1m); enforce 2s for the test
"$@" & pid=$!
( sleep 2; kill "$pid" 2>/dev/null ) & k=$!
wait "$pid" 2>/dev/null; rc=$?
kill "$k" 2>/dev/null
exit $rc
EOF
chmod +x bin/*; export PATH="$WD/bin:$PATH"

# ---- resolved script (Nextflow ${...} filled; timeout uses coreutils; TMO tiny=1m to trip) ----
contig=chr1; fai=test.fai; vcf=all_in.vcf.gz; bam=test.bam; ref=ref.fa; cpus=4; use_indels=""
sample=COLO829; type=tumor; CS=20000000; TMO=1
OUT=phased_${sample}_${type}_${contig}
CLEN=$(awk -v c="$contig" '$1==c{print $2}' "$fai"); [ -z "$CLEN" ] && CLEN=250000000
gzip -dc "$vcf" > all.vcf
bgzip -c all.vcf > all.vcf.gz && tabix -f -p vcf all.vcf.gz
: > parts.list; start=0; idx=0
while [ $start -lt $CLEN ]; do
  end=$(( start + CS )); if [ $end -gt $CLEN ]; then end=$CLEN; fi
  reg="$contig:$(( start + 1 ))-$end"
  bcftools view -r "$reg" all.vcf.gz -Ov -o chunk.vcf 2>/dev/null || : > chunk.vcf
  nsnp=$(grep -vc '^#' chunk.vcf || true)
  if [ "$nsnp" -gt 0 ]; then
    part=$(printf "part_%05d" $idx)
    samtools view -b "$bam" "$reg" > chunk.bam 2>/dev/null; samtools index chunk.bam
    if timeout ${TMO}m longphase phase --ont -o $part -s chunk.vcf -b chunk.bam -r "$ref" -t $cpus $use_indels 2>> phase.log; then
      bgzip -f $part.vcf
    else
      echo "PHASE_FALLBACK chunk $reg exceeded ${TMO}m -> UNPHASED" | tee -a phase.log
      bgzip -c chunk.vcf > $part.vcf.gz
    fi
    tabix -f -p vcf $part.vcf.gz
    echo "$part.vcf.gz" >> parts.list; idx=$(( idx + 1 ))
  fi
  start=$end
done
if [ -s parts.list ]; then bcftools concat -f parts.list -Oz -o $OUT.vcf.gz 2>> phase.log; else bgzip -c all.vcf > $OUT.vcf.gz; fi
tabix -f -p vcf $OUT.vcf.gz

echo "=== parts.list ==="; cat parts.list
echo "=== phase.log ==="; cat phase.log 2>/dev/null
echo "=== output sites (should be 3, chunk2 unphased-fallback still present) ==="
gzip -dc $OUT.vcf.gz | grep -vc '^#'
echo "=== output has tbi? ==="; ls -la $OUT.vcf.gz.tbi
echo "TEST_OK"
