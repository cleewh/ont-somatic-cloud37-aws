#!/usr/bin/env bash
# cloud37 B1c — per-input ALIGN job (runs as an AWS Batch job on on-demand EC2).
# Auto-detects uBAM vs aligned for ONE input BAM and produces an aligned+indexed
# BAM written DIRECTLY to S3 (no HealthOmics scratch/finalize involved).
#
# The minimap2 recipe is byte-for-byte the same as the validated HealthOmics
# minimap2_alignment process (samtools reset -> fastq -> minimap2 lr:hq -> reheader
# -> sort --write-index), so alignment results stay concordant with cloud29/34/35.
#
# Env (set by the Batch job definition / Step Functions):
#   IN_BAM     s3://.../input.(u)bam        input BAM (uBAM or aligned)
#   OUT_BAM    s3://.../<sample>/xxx_aligned.bam   destination (index -> OUT_BAM.bai)
#   REF        s3://.../GRCh38_no_alt_analysis_set.fna   reference (+ .fai sibling)
#   MAP_THREADS(=16) SORT_THREADS(=6) BAM2FQ_THREADS(=2)
#   WORK       local scratch dir (default /scratch)
set -euo pipefail

: "${IN_BAM:?}"; : "${OUT_BAM:?}"; : "${REF:?}"
MAP_THREADS="${MAP_THREADS:-16}"; SORT_THREADS="${SORT_THREADS:-6}"; BAM2FQ_THREADS="${BAM2FQ_THREADS:-2}"
# Unique per-job scratch dir + cleanup on exit, so a reused Batch instance is left
# clean for the next job (align scratch is ~500GB; leftovers otherwise fill the volume).
WORK="${WORK:-/scratch}"; WORK="${WORK%/}/job-${AWS_BATCH_JOB_ID:-$$}"
mkdir -p "$WORK"; cd "$WORK"
trap 'cd /; rm -rf "$WORK" 2>/dev/null || true' EXIT

echo "[align_job] IN_BAM=$IN_BAM OUT_BAM=$OUT_BAM"
aws s3 cp "$IN_BAM" in.bam
aws s3 cp "$REF" ref.fna
aws s3 cp "${REF}.fai" ref.fna.fai || samtools faidx ref.fna

# --- classify: aligned vs uBAM ---
# Disable pipefail locally: `head -1` closes the pipe early, giving samtools a SIGPIPE
# (nonzero) that would otherwise corrupt the flag extraction under `set -o pipefail`.
set +o pipefail
SQ=$(samtools view -H in.bam 2>/dev/null | grep -c '^@SQ' || true)
FIRST_FLAG=$(samtools view in.bam 2>/dev/null | head -1 | awk '{print $2}' || true)
set -o pipefail
SQ=${SQ:-0}
FIRST_FLAG=${FIRST_FLAG:-4}
UNMAPPED=$(( FIRST_FLAG & 4 ))

if [ "$SQ" -gt 0 ] && [ "$UNMAPPED" -eq 0 ]; then
    echo "[align_job] input is ALIGNED (@SQ=$SQ) -> ensure index, no realign"
    mv in.bam out.bam
    samtools quickcheck out.bam
    samtools index -@ "$SORT_THREADS" out.bam
else
    echo "[align_job] input is uBAM (@SQ=$SQ) -> minimap2 align (recipe == HealthOmics minimap2_alignment)"
    RESET="samtools reset -x tp,cm,s1,s2,NM,MD,AS,SA,ms,nn,ts,cg,cs,dv,de,rl"
    samtools view -H --no-PG in.bam > reads.header || true
    $RESET --no-PG in.bam -o - \
      | samtools fastq -T 1 -@ "$BAM2FQ_THREADS" - \
      | minimap2 -y -t "$MAP_THREADS" -a -x lr:hq --cap-kalloc 100m --cap-sw-mem 50m ref.fna - \
      | samtools sort -@ "$SORT_THREADS" --write-index -o out.bam##idx##out.bam.bai -O bam --reference ref.fna -
    samtools quickcheck out.bam
fi

# --- upload aligned + index directly to S3 ---
aws s3 cp out.bam "$OUT_BAM"
aws s3 cp out.bam.bai "${OUT_BAM}.bai"
echo "[align_job] DONE -> $OUT_BAM (+ .bai)"
