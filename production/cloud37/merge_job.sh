#!/usr/bin/env bash
# cloud37 B1c — MERGE job (runs as an AWS Batch job). Merges the TWO already-aligned
# tumor BAMs (produced by the parallel align jobs) into one sorted+indexed tumor BAM,
# writes it directly to S3, and emits manifest.json describing the whole pair.
# Only invoked when there are 2 tumor files. For 1 tumor the align job's output IS
# the tumor_aligned.bam and this step is skipped by the state machine.
#
# Env:
#   T1_BAM   s3://.../t1_aligned.bam      aligned tumor 1 (from align job)
#   T2_BAM   s3://.../t2_aligned.bam      aligned tumor 2 (from align job)
#   OUT_BAM  s3://.../<prefix>/aligned_bams/tumor_aligned.bam
#   SAMPLE   sample_name (for the @RG SM tag + manifest)
#   THREADS  (default 16)
set -euo pipefail
: "${T1_BAM:?}"; : "${T2_BAM:?}"; : "${OUT_BAM:?}"; : "${SAMPLE:?}"
THREADS="${THREADS:-16}"
# Unique per-job scratch dir + cleanup on exit (see align_job.sh rationale).
WORK="${WORK:-/scratch}"; WORK="${WORK%/}/job-${AWS_BATCH_JOB_ID:-$$}"
mkdir -p "$WORK"; cd "$WORK"
trap 'cd /; rm -rf "$WORK" 2>/dev/null || true' EXIT

echo "[merge_job] merging $T1_BAM + $T2_BAM -> $OUT_BAM"
aws s3 cp "$T1_BAM" t1.bam
aws s3 cp "$T2_BAM" t2.bam

# sort-preserving merge of two coordinate-sorted aligned BAMs (combined header keeps both @RG)
samtools merge -@ "$THREADS" -f -c -p merged.bam t1.bam t2.bam
# normalise SM tag to the sample name (in-place reheader when header length allows)
samtools view -H merged.bam | sed "s/\tSM:[^\t]*/\tSM:${SAMPLE}/" > hdr.sam
if samtools reheader -i hdr.sam merged.bam 2>/dev/null; then :; else
    samtools reheader hdr.sam merged.bam > merged_fixed.bam && mv merged_fixed.bam merged.bam
fi
samtools quickcheck merged.bam
samtools index -@ "$THREADS" merged.bam

aws s3 cp merged.bam "$OUT_BAM"
aws s3 cp merged.bam.bai "${OUT_BAM}.bai"
echo "[merge_job] DONE -> $OUT_BAM (+ .bai)"
