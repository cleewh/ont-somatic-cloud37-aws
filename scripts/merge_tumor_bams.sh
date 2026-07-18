#!/bin/bash
set -eux
BUCKET=ont-lrs-somatic-poc-apse1-687677765589
REGION=ap-southeast-1
SAMTOOLS_IMG=quay.io/biocontainers/samtools:1.19.2--h50ea8bc_0

echo "BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
systemctl start docker || true
docker pull $SAMTOOLS_IMG

cd /home/data
rm -f merged_tumor.bam merged_tumor.bam.bai

# Inputs are individually coordinate-sorted aligned BAMs. `samtools merge`
# performs a sort-preserving merge (merge-sort), producing a globally
# coordinate-sorted BAM that can be indexed. `samtools cat` does NOT do this.
echo "MERGE $(date -u +%H:%M:%SZ)"
docker run --rm -v /home/data:/data -w /data $SAMTOOLS_IMG \
  samtools merge -@ 8 -f -c -p merged_tumor.bam PAU59949.bam PAU61426.bam
ls -lh /home/data/merged_tumor.bam

echo "INDEX $(date -u +%H:%M:%SZ)"
docker run --rm -v /home/data:/data -w /data $SAMTOOLS_IMG \
  samtools index -@ 8 merged_tumor.bam
ls -lh /home/data/merged_tumor.bam.bai

echo "VERIFY $(date -u +%H:%M:%SZ)"
docker run --rm -v /home/data:/data -w /data $SAMTOOLS_IMG \
  samtools quickcheck merged_tumor.bam && echo "quickcheck OK"

echo "UPLOAD $(date -u +%H:%M:%SZ)"
aws s3 cp --region $REGION merged_tumor.bam s3://$BUCKET/inputs/tumor_merged/merged_tumor.bam --no-progress
aws s3 cp --region $REGION merged_tumor.bam.bai s3://$BUCKET/inputs/tumor_merged/merged_tumor.bam.bai --no-progress

echo "NORMAL $(date -u +%H:%M:%SZ)"
aws s3 cp --region $REGION s3://$BUCKET/inputs/normal_bams/PAU59807.d052sup4305mCG_5hmCGvHg38.bam s3://$BUCKET/inputs/normal_single/normal.bam --no-progress
aws s3 cp --region $REGION s3://$BUCKET/inputs/normal_bams/PAU59807.d052sup4305mCG_5hmCGvHg38.bam.bai s3://$BUCKET/inputs/normal_single/normal.bam.bai --no-progress

echo "DONE $(date -u +%Y-%m-%dT%H:%M:%SZ)" | aws s3 cp --region $REGION - s3://$BUCKET/inputs/tumor_merged/_MERGE_COMPLETE

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 terminate-instances --region $REGION --instance-ids $IID
