#!/bin/bash
# User-data for the ephemeral BAM-merge EC2 instance.
# Runs as root under cloud-init. Streams logs to /var/log/merge.log and to S3.
# Merges two tumor BAMs into a single BAM with samtools cat (no re-sort),
# indexes it, uploads to S3, mirrors the normal BAM to a single-file prefix,
# then self-terminates.

set -eux
exec > >(tee -a /var/log/merge.log | aws s3 cp --region ap-southeast-1 - s3://ont-lrs-somatic-poc-apse1-687677765589/inputs/tumor_merged/_merge.log 2>/dev/null) 2>&1

BUCKET=ont-lrs-somatic-poc-apse1-687677765589
REGION=ap-southeast-1

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) BEGIN MERGE ==="

dnf install -y samtools awscli-2 || {
  dnf install -y gcc make bzip2-devel xz-devel ncurses-devel zlib-devel unzip curl
  cd /tmp
  curl -LO https://github.com/samtools/samtools/releases/download/1.19.2/samtools-1.19.2.tar.bz2
  tar xjf samtools-1.19.2.tar.bz2
  cd samtools-1.19.2 && ./configure && make -j"$(nproc)" && make install
}

samtools --version | head -1
aws --version

mkdir -p /home/data && cd /home/data

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) DOWNLOAD TUMORS ==="
aws s3 cp --region "$REGION" "s3://$BUCKET/inputs/tumor_bams/PAU59949.d052sup4305mCG_5hmCGvHg38.bam" PAU59949.bam --no-progress &
aws s3 cp --region "$REGION" "s3://$BUCKET/inputs/tumor_bams/PAU61426.d052sup4305mCG_5hmCGvHg38.bam" PAU61426.bam --no-progress &
wait

ls -lh /home/data

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) MERGE (samtools cat) ==="
samtools cat -o merged_tumor.bam PAU59949.bam PAU61426.bam
ls -lh /home/data/merged_tumor.bam

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) INDEX ==="
samtools index -@ "$(nproc)" merged_tumor.bam

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) UPLOAD ==="
aws s3 cp --region "$REGION" merged_tumor.bam "s3://$BUCKET/inputs/tumor_merged/merged_tumor.bam" --no-progress
aws s3 cp --region "$REGION" merged_tumor.bam.bai "s3://$BUCKET/inputs/tumor_merged/merged_tumor.bam.bai" --no-progress

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) NORMAL MIRROR ==="
aws s3 cp --region "$REGION" \
  "s3://$BUCKET/inputs/normal_bams/PAU59807.d052sup4305mCG_5hmCGvHg38.bam" \
  "s3://$BUCKET/inputs/normal_single/normal.bam" --no-progress
aws s3 cp --region "$REGION" \
  "s3://$BUCKET/inputs/normal_bams/PAU59807.d052sup4305mCG_5hmCGvHg38.bam.bai" \
  "s3://$BUCKET/inputs/normal_single/normal.bam.bai" --no-progress

echo "DONE $(date -u +%Y-%m-%dT%H:%M:%SZ)" | aws s3 cp --region "$REGION" - "s3://$BUCKET/inputs/tumor_merged/_MERGE_COMPLETE"

echo "=== SELF-TERMINATE ==="
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
