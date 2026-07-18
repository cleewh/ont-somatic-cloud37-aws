#!/bin/bash
# cloud37 amd64 image builder — runs once on an on-demand AL2023 x86_64 EC2,
# then self-terminates. Streams a build log to S3 for post-mortem verification.
set -x
REGION="ap-southeast-1"
ACCT="687677765589"
REPO="cloud37-align"
ECR="${ACCT}.dkr.ecr.${REGION}.amazonaws.com"
BUILD_S3="s3://ont-lrs-somatic-poc-apse1-687677765589/workflow-artifacts/cloud37-build"
LOG="/var/log/cloud37-build.log"
STATUS="UNKNOWN"

exec > >(tee -a "$LOG") 2>&1

finish() {
  aws s3 cp "$LOG" "${BUILD_S3}/build-logs/build-$(date -u +%Y%m%dT%H%M%SZ)-${STATUS}.log" --region "$REGION" || true
  shutdown -h now
}
trap finish EXIT

echo "=== cloud37 builder start $(date -u) ==="

dnf -y install docker awscli unzip || { STATUS="FAIL_INSTALL"; exit 1; }
systemctl enable --now docker || { STATUS="FAIL_DOCKER_START"; exit 1; }

mkdir -p /build && cd /build
aws s3 sync "${BUILD_S3}/" /build/ --region "$REGION" --exclude "build-logs/*" || { STATUS="FAIL_S3_SYNC"; exit 1; }
ls -la /build

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR" || { STATUS="FAIL_ECR_LOGIN"; exit 1; }

docker build --platform linux/amd64 -t "${ECR}/${REPO}:latest" /build || { STATUS="FAIL_BUILD"; exit 1; }
docker push "${ECR}/${REPO}:latest" || { STATUS="FAIL_PUSH"; exit 1; }

# scrub cached ECR credentials from the (about-to-be-terminated) instance
docker logout "$ECR" || true

STATUS="SUCCESS"
echo "=== cloud37 builder SUCCESS $(date -u) ==="
