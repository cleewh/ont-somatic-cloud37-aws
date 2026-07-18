#!/bin/bash
# ============================================================================
# merge_pair.sh  --  per-sample tumor-BAM merge for the 150-pair production run
# ----------------------------------------------------------------------------
# Each customer sample = 2 tumor BAMs + 1 normal BAM. wf-somatic-variation
# v1.5.1 requires a SINGLE bam_tumor file on AWS HealthOmics (S3 directory and
# glob URIs do not work - see POC findings), so the two tumor BAMs must be
# merged into one sorted, indexed BAM before each HealthOmics run.
#
# COMPUTE CHOICE: ON-DEMAND, not spot. The merge is on the critical path for
# every pair; a spot reclaim mid-merge on a ~290 GB file wastes the download +
# partial merge and delays that pair. The spot saving (~$0.15/pair, ~$22 across
# 150) is not worth the reliability risk. On-demand m6i.2xlarge it is.
#
# This script is designed to run on an ephemeral on-demand EC2 instance (via
# SSM Send-Command or user-data) that self-terminates when done. It is
# idempotent: if the merged output already exists in S3 it exits early.
#
# Required env vars (or edit the defaults):
#   SAMPLE        sample/alias name, e.g. "PT-0007"          (becomes @RG SM)
#   TUMOR1_S3     s3:// URI of tumor BAM 1
#   TUMOR2_S3     s3:// URI of tumor BAM 2
#   NORMAL_S3     s3:// URI of the normal BAM
#   OUT_PREFIX    s3:// prefix for merged outputs, e.g.
#                 s3://<bucket>/inputs/<SAMPLE>/
#   REGION        AWS region (default ap-southeast-1)
#
# Produces under $OUT_PREFIX:
#   tumor_merged/merged_tumor.bam(+.bai)   <- pass as --bam_tumor
#   normal_single/normal.bam(+.bai)        <- pass as --bam_normal
#   _MERGE_COMPLETE                        <- sentinel marker
# ============================================================================
set -euo pipefail

: "${SAMPLE:?set SAMPLE}"
: "${TUMOR1_S3:?set TUMOR1_S3}"
: "${TUMOR2_S3:?set TUMOR2_S3}"
: "${NORMAL_S3:?set NORMAL_S3}"
: "${OUT_PREFIX:?set OUT_PREFIX (must end with /)}"
REGION="${REGION:-ap-southeast-1}"
SAMTOOLS_IMG="quay.io/biocontainers/samtools:1.19.2--h50ea8bc_0"

TUMOR_OUT="${OUT_PREFIX}tumor_merged/merged_tumor.bam"
NORMAL_OUT="${OUT_PREFIX}normal_single/normal.bam"
MARKER="${OUT_PREFIX}_MERGE_COMPLETE"

echo "BEGIN $SAMPLE $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Idempotency: skip if already done.
if aws s3 ls "$MARKER" --region "$REGION" >/dev/null 2>&1; then
  echo "SKIP: $MARKER already exists; merge previously completed for $SAMPLE"
  exit 0
fi

# Docker + samtools (Amazon Linux 2023 default repos lack samtools).
dnf install -y docker >/dev/null
systemctl start docker
docker pull "$SAMTOOLS_IMG" >/dev/null

mkdir -p /home/data && cd /home/data

echo "DOWNLOAD $(date -u +%H:%M:%SZ)"
aws s3 cp "$TUMOR1_S3" t1.bam --region "$REGION" --no-progress &
aws s3 cp "$TUMOR2_S3" t2.bam --region "$REGION" --no-progress &
aws s3 cp "$NORMAL_S3" normal.bam --region "$REGION" --no-progress &
wait

# Sort-preserving merge of two already-coordinate-sorted BAMs. `samtools cat`
# is NOT used: it concatenates blocks and yields a non-globally-sorted BAM that
# fails indexing. `samtools merge` does the merge-sort and stays indexable.
# -c/-p collapse identical @RG/@PG headers so the merged file carries one SM.
echo "MERGE $(date -u +%H:%M:%SZ)"
docker run --rm -v /home/data:/data -w /data "$SAMTOOLS_IMG" \
  samtools merge -@ "$(nproc)" -f -c -p merged_tumor.bam t1.bam t2.bam

# Guarantee a single unified SM tag (defensive: if the two tumor BAMs disagreed
# on SM, rewrite to $SAMPLE so xam_ingress treats them as one sample).
docker run --rm -v /home/data:/data -w /data "$SAMTOOLS_IMG" bash -c "
  samtools view -H merged_tumor.bam | sed 's/\tSM:[^\t]*/\tSM:${SAMPLE}/' > hdr.sam
  samtools reheader hdr.sam merged_tumor.bam > merged_tumor.reheader.bam
  mv merged_tumor.reheader.bam merged_tumor.bam
"

echo "INDEX $(date -u +%H:%M:%SZ)"
docker run --rm -v /home/data:/data -w /data "$SAMTOOLS_IMG" \
  samtools index -@ "$(nproc)" merged_tumor.bam
docker run --rm -v /home/data:/data -w /data "$SAMTOOLS_IMG" \
  samtools quickcheck merged_tumor.bam && echo "quickcheck OK"

docker run --rm -v /home/data:/data -w /data "$SAMTOOLS_IMG" \
  samtools index -@ "$(nproc)" normal.bam

echo "UPLOAD $(date -u +%H:%M:%SZ)"
aws s3 cp merged_tumor.bam     "$TUMOR_OUT"        --region "$REGION" --no-progress
aws s3 cp merged_tumor.bam.bai "${TUMOR_OUT}.bai"  --region "$REGION" --no-progress
aws s3 cp normal.bam           "$NORMAL_OUT"       --region "$REGION" --no-progress
aws s3 cp normal.bam.bai       "${NORMAL_OUT}.bai" --region "$REGION" --no-progress

echo "DONE $SAMPLE $(date -u +%Y-%m-%dT%H:%M:%SZ)" | aws s3 cp - "$MARKER" --region "$REGION"
echo "COMPLETE $SAMPLE"
