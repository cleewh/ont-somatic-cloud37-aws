#!/usr/bin/env bash
# v3 FAITHFUL phasing micro-benchmark: reproduce the cloud25 chr1 clairs_phase hang in
# isolation, then test the fixes. Key vs v2: WHOLE chr1 (production unit) + het SNPs called
# on FULL depth (keeps the deep-region hets that drive the hang; v2 called them on the
# capped BAM and thus removed the pathology -> false 114s baseline).
#   A baseline  longphase -t 4  full-depth whole chr1        (expect TIMEOUT = hang reproduced)
#   D threads   longphase -t 16 full-depth whole chr1        (does more CPU help?)
#   B depthgate exclude reads in >1000x windows              (Option 1)
#   C downsample deep-region reads to ~1000x (split+merge)   (Option 2, 1000x)
#   CTRL        chr20 shallow                                 (fix must not slow normal regions)
set -uo pipefail
BUCKET=ont-lrs-somatic-poc-apse1-687677765589
REGION=ap-southeast-1
PREFIX=analysis/phase-benchmark-v4
LOG=/root/phase_bench.log
RESULTS=/root/results
mkdir -p "$RESULTS"
export AWS_DEFAULT_REGION=$REGION AWS_REGION=$REGION

log(){ echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; aws s3 cp "$LOG" "s3://$BUCKET/$PREFIX/_bench.log" >/dev/null 2>&1 || true; }
TID=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TID" http://169.254.169.254/latest/meta-data/instance-id)
finish(){ log "FINISH rc=$? - uploading + self-terminating $IID";
  aws s3 cp "$RESULTS" "s3://$BUCKET/$PREFIX/results/" --recursive >/dev/null 2>&1 || true
  aws s3 cp /root/timing.tsv "s3://$BUCKET/$PREFIX/timing.tsv" >/dev/null 2>&1 || true
  aws s3 cp "$LOG" "s3://$BUCKET/$PREFIX/_bench.log" >/dev/null 2>&1 || true
  aws ec2 terminate-instances --instance-ids "$IID" --region "$REGION" >/dev/null 2>&1 || true; }
trap finish EXIT

log "START $IID; install tooling"
cd /root
curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba >/dev/null 2>&1
export MAMBA_ROOT_PREFIX=/root/mamba
eval "$(./bin/micromamba shell hook -s posix)"
./bin/micromamba create -y -n bench -c bioconda -c conda-forge samtools mosdepth longphase bcftools htslib >/dev/null 2>&1
micromamba activate bench
log "versions: $(samtools --version|head -1) | longphase=$(longphase --version 2>&1|head -1) | $(bcftools --version|head -1)"

CRED=$(curl -s -H "X-aws-ec2-metadata-token: $TID" http://169.254.169.254/latest/meta-data/iam/security-credentials/ubam-reset-ec2-role)
export AWS_ACCESS_KEY_ID=$(echo "$CRED"|python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CRED"|python3 -c "import sys,json;print(json.load(sys.stdin)['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CRED"|python3 -c "import sys,json;print(json.load(sys.stdin)['Token'])")

REF=/root/ref.fna
BAMS3=s3://$BUCKET/inputs/tumor_merged/merged_tumor.bam
aws s3 cp s3://$BUCKET/inputs/references/GRCh38_no_alt_analysis_set.fna $REF >/dev/null 2>&1
aws s3 cp s3://$BUCKET/inputs/references/GRCh38_no_alt_analysis_set.fna.fai $REF.fai >/dev/null 2>&1

log "slice WHOLE chr1 (production phasing unit) via S3 index-seek"
samtools view -b -@ 15 "$BAMS3" chr1 > chr1.bam 2>>"$LOG"; samtools index -@ 15 chr1.bam
log "slice chr20 shallow control"
samtools view -b -@ 15 "$BAMS3" chr20 > chr20.bam 2>>"$LOG"; samtools index -@ 15 chr20.bam
log "slice sizes: $(du -h chr1.bam chr20.bam|tr '\n' ' ')"

# depth map (500bp) over whole chr1 -> deep/keep BEDs + peak
log "mosdepth 500bp on chr1"
mosdepth -x -n -t 15 --by 500 chr1d chr1.bam 2>>"$LOG"
gzip -dc chr1d.regions.bed.gz > chr1_depth.bed
PEAK=$(sort -k4,4gr chr1_depth.bed | head -1 | cut -f4)
awk 'BEGIN{FS=OFS="\t"} $4+0>1000 {print $1,$2,$3}' chr1_depth.bed > deep_gt1000.bed
awk 'BEGIN{FS=OFS="\t"} $4+0<=1000 {print $1,$2,$3}' chr1_depth.bed > keep_le1000.bed
cp chr1d.regions.bed.gz "$RESULTS/" 2>/dev/null || true
log "chr1 PEAK 500bp depth=${PEAK}x; deep(>1000x) windows: $(wc -l < deep_gt1000.bed)"

# ---- v4: build GATED + CAPPED BAMs FIRST (per-region, fast), then call hets on the
# CAPPED bam. Per-region cap keeps NORMAL regions at full depth (realistic het density,
# unlike v2's global subsample) while bounding deep regions to <=1000x so het-calling is
# fast. longphase in the BASELINE then reads the FULL-depth bam at these hets -> reproduces
# the deep-region read load = the hang; B/C read gated/capped bams -> should be fast. ----
log "gate: drop reads in >1000x windows"
samtools view -b -@ 15 -M -L keep_le1000.bed chr1.bam > chr1_gated.bam 2>>"$LOG"; samtools index -@ 15 chr1_gated.bam

log "cap deep regions to ~1000x via split+merge (deep reads subsampled by 1000/PEAK, non-deep kept full)"
FR=$(python3 -c "p=$PEAK; print('%.5f'%min(0.999,1000.0/p))")
samtools view -b -@ 15 -M -L keep_le1000.bed chr1.bam > cap_keep.bam 2>>"$LOG"
samtools view -b -@ 15 -M -L deep_gt1000.bed -s "42.$(echo $FR | cut -d. -f2)" chr1.bam > cap_deep.bam 2>>"$LOG"
samtools merge -f -@ 15 chr1_capped.bam cap_keep.bam cap_deep.bam 2>>"$LOG"
samtools index -@ 15 chr1_capped.bam
log "capped frac for deep=$FR; capped size $(du -h chr1_capped.bam|cut -f1)"

# ---- het SNPs called on the CAPPED bam (<=1000x -> fast). Reused across all experiments. ----
log "het calling on CAPPED chr1 bam (<=1000x, fast) + chr20"
bcftools mpileup -f "$REF" -r chr1 -q 1 -Q 5 -d 1000 -Ou chr1_capped.bam 2>>"$LOG" \
  | bcftools call -mv -Ou 2>>"$LOG" \
  | bcftools view -v snps -g het -Oz -o hets_chr1.vcf.gz 2>>"$LOG"
bcftools index -t hets_chr1.vcf.gz 2>>"$LOG"
gzip -dc hets_chr1.vcf.gz > hets_chr1.vcf
log "chr1 het SNPs: $(grep -vc '^#' hets_chr1.vcf)  (in deep>1000x windows: $(bcftools view -R deep_gt1000.bed hets_chr1.vcf.gz 2>/dev/null | grep -vc '^#'))"
bcftools view -R keep_le1000.bed hets_chr1.vcf.gz -Ov -o hets_gated.vcf 2>>"$LOG" || cp hets_chr1.vcf hets_gated.vcf
bcftools mpileup -f "$REF" -r chr20 -q 1 -Q 5 -d 1000 -Ou chr20.bam 2>>"$LOG" \
  | bcftools call -mv -Ou 2>>"$LOG" | bcftools view -v snps -g het -Oz -o hets_chr20.vcf.gz 2>>"$LOG"
gzip -dc hets_chr20.vcf.gz > hets_chr20.vcf

echo -e "experiment\tstatus\twall_sec\tnotes" > /root/timing.tsv
run_exp(){ local label=$1; shift; local tmo=$1; shift
  log "EXP $label START (timeout ${tmo}s): $*"; local t0=$SECONDS
  timeout "$tmo" "$@" >>"$LOG" 2>&1; local rc=$?; local wall=$((SECONDS-t0))
  local st="COMPLETED"; [ $rc -eq 124 ] && st="TIMEOUT"; [ $rc -ne 0 ] && [ $rc -ne 124 ] && st="ERR_$rc"
  log "EXP $label $st wall=${wall}s rc=$rc"; echo -e "$label\t$st\t$wall\t$*" >> /root/timing.tsv; }

run_exp A_baseline_t4     2400 longphase phase --ont -o phA -s hets_chr1.vcf   -b chr1.bam        -r "$REF" -t 4
run_exp D_threads_t16     2400 longphase phase --ont -o phD -s hets_chr1.vcf   -b chr1.bam        -r "$REF" -t 16
run_exp B_depthgate_1000  2400 longphase phase --ont -o phB -s hets_gated.vcf  -b chr1_gated.bam  -r "$REF" -t 4
run_exp C_downsample_1000 2400 longphase phase --ont -o phC -s hets_chr1.vcf   -b chr1_capped.bam -r "$REF" -t 4
run_exp CTRL_chr20_t4     2400 longphase phase --ont -o phCTRL -s hets_chr20.vcf -b chr20.bam     -r "$REF" -t 4

for f in phA phB phC phD phCTRL; do [ -s "$f.vcf" ] && bgzip -f "$f.vcf" && cp "$f.vcf.gz" "$RESULTS/" 2>/dev/null || true; done
cp /root/timing.tsv "$RESULTS/" 2>/dev/null || true
log "ALL DONE; timing:"; cat /root/timing.tsv | tee -a "$LOG"
