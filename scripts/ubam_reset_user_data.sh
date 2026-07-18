#!/bin/bash
# User-data for the ephemeral uBAM-reset EC2 instance.
# Creates true unaligned BAMs (uBAMs) from the aligned COLO829 BAMs via
# `samtools reset` + stripping @SQ header lines, so the wf-somatic-variation
# ingress (check_for_alignment) treats them as unaligned and runs minimap2.
# This lets us measure the FULL per-run cost including alignment (our POC
# used pre-aligned BAMs, so alignment was skipped). Sequential per file with
# cleanup; self-terminates at end. Uploads to s3://.../inputs/ubam/.
set -eux
BUCKET=ont-lrs-somatic-poc-apse1-687677765589
REGION=ap-southeast-1
IMG=quay.io/biocontainers/samtools:1.19.2--h50ea8bc_0
exec > >(tee -a /var/log/ubam.log | aws s3 cp --region $REGION - s3://$BUCKET/inputs/ubam/_ubam.log 2>/dev/null) 2>&1
echo "=== $(date -u +%FT%TZ) BEGIN uBAM RESET ==="
aws configure set default.s3.multipart_chunksize 128MB
aws configure set default.s3.max_concurrent_requests 16
systemctl start docker || { dnf install -y docker && systemctl start docker; }
docker pull $IMG
mkdir -p /home/data && cd /home/data
NP=$(nproc)
process () {
  local SRC="$1" DST="$2" L="$3"
  echo "=== $(date -u +%FT%TZ) DOWNLOAD $SRC ==="
  aws s3 cp --region $REGION "s3://$BUCKET/$SRC" "$L.in.bam" --no-progress
  echo "=== $(date -u +%FT%TZ) RESET+STRIP -> $DST ==="
  docker run --rm -v /home/data:/data -w /data $IMG bash -c \
    "samtools reset -@ $NP -O bam -o - $L.in.bam | samtools reheader -c 'grep -v \"^@SQ\"' - > $L.ubam.bam"
  docker run --rm -v /home/data:/data -w /data $IMG samtools quickcheck $L.ubam.bam && echo quickcheck_OK
  NSQ=$(docker run --rm -v /home/data:/data -w /data $IMG bash -c "samtools view -H $L.ubam.bam | grep -c '^@SQ' || true")
  echo "SQ_lines=$NSQ"
  aws s3 cp --region $REGION "$L.ubam.bam" "s3://$BUCKET/$DST" --no-progress
  rm -f "$L.in.bam" "$L.ubam.bam"
}
process "inputs/tumor_bams/PAU59949.d052sup4305mCG_5hmCGvHg38.bam" "inputs/ubam/tumor1_PAU59949.ubam.bam" t1
process "inputs/tumor_bams/PAU61426.d052sup4305mCG_5hmCGvHg38.bam" "inputs/ubam/tumor2_PAU61426.ubam.bam" t2
process "inputs/normal_single/normal.bam" "inputs/ubam/normal_PAU59807.ubam.bam" n1
echo "DONE $(date -u +%FT%TZ)" | aws s3 cp --region $REGION - s3://$BUCKET/inputs/ubam/_UBAM_COMPLETE
echo "=== SELF-TERMINATE ==="
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 terminate-instances --region $REGION --instance-ids "$IID"
