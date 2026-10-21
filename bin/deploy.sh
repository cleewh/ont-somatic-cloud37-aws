#!/usr/bin/env bash
# Set up the pipeline in the AWS account the AWS CLI is signed in to, in Asia Pacific
# (Singapore). Checks the prerequisites, creates the S3 bucket, finds the network and
# builds the workflow package, then starts production/cloud37/bootstrap.sh in the
# background. Setup takes about 30 minutes; follow it with: bash bin/status.sh --wait
# Safe to run again at any time: finished work is skipped.
#
# Usage, from the repository folder:  bash bin/deploy.sh
source "$(dirname "$0")/_common.sh"

if alive bootstrap.lock; then
  echo "Setup is already running. Check progress with: bash bin/status.sh --wait"
  exit 0
fi

echo "Checking prerequisites"
command -v aws >/dev/null 2>&1 \
  || need "install the AWS CLI (SETUP.md section 1, step 2), then restart Kiro."
ver="$(aws --version 2>&1 | sed -n 's#^aws-cli/\([0-9][0-9.]*\).*#\1#p')"
[[ "$ver" == 2.* ]] || need "the AWS CLI is version ${ver:-unknown}; version 2 is needed (SETUP.md section 1, step 2)."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1 \
  || need "install Python 3.8 or later (SETUP.md section 1, step 2)."
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>&1)"; then
  need "the AWS CLI isn't signed in to your AWS account. Run: aws login   (SETUP.md section 1, step 4)
  The AWS CLI said: ${ACCOUNT}"
fi
echo "  AWS CLI ${ver}, account ${ACCOUNT}, region ${REGION} (Asia Pacific, Singapore)"

limit="$(vcpu_limit)"
if [[ -n "$limit" ]] && (( limit < 128 )); then
  pending="$(aws service-quotas list-requested-service-quota-change-history-by-quota \
    --service-code ec2 --quota-code L-1216C47A \
    --query "RequestedQuotas[?Status=='PENDING' || Status=='CASE_OPENED'] | [0].DesiredValue" \
    --output text 2>/dev/null || true)"
  echo "  NOTE: your EC2 limit in Singapore is ${limit} vCPUs; runs need 128."
  if [[ "$pending" =~ ^[0-9] ]]; then
    echo "        Your request for ${pending%%.*} is waiting for AWS approval. Setup continues."
  else
    echo "        Request the increase now (SETUP.md section 1, step 5). Setup continues."
  fi
else
  echo "  EC2 limit: ${limit:-unknown} vCPUs"
fi

# Reuse the bucket and network from an earlier run, if any.
unset BUCKET SUBNETS SECURITY_GROUP
if [[ -f setup.env ]]; then
  source ./setup.env
  export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
fi
BUCKET="${BUCKET:-ont-somatic-${ACCOUNT}-${REGION}}"

echo "Storage bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  loc="$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text)"
  [[ "$loc" == "$REGION" ]] \
    || need "bucket ${BUCKET} is in ${loc}, but the pipeline needs a bucket in ${REGION}. Delete the BUCKET line from setup.env, then run bash bin/deploy.sh again."
  echo "  using s3://${BUCKET}"
else
  if ! err="$(aws s3api create-bucket --bucket "$BUCKET" \
                --create-bucket-configuration "LocationConstraint=${REGION}" 2>&1)"; then
    need "couldn't create bucket ${BUCKET}. AWS said: ${err}"
  fi
  echo "  created s3://${BUCKET}"
fi

echo "Network"
if [[ -z "${SUBNETS:-}" || -z "${SECURITY_GROUP:-}" ]]; then
  vpc="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
  if [[ "$vpc" == vpc-* ]]; then
    SUBNETS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" Name=default-for-az,Values=true \
                 --query 'Subnets[].SubnetId' --output text | tr '\t' ',')"
    SECURITY_GROUP="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" \
                        Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)"
  fi
fi
write_env() {
  cat > setup.env <<EOF
# Written by bin/deploy.sh. The pipeline runs in Asia Pacific (Singapore).
export AWS_REGION=${REGION} AWS_DEFAULT_REGION=${REGION} AWS_PAGER=""
export BUCKET=${BUCKET}
export SUBNETS=${SUBNETS:-}
export SECURITY_GROUP=${SECURITY_GROUP:-}
EOF
}
if [[ "${SUBNETS:-}" != subnet-* || "${SECURITY_GROUP:-}" != sg-* ]]; then
  SUBNETS="" SECURITY_GROUP=""
  write_env
  need "your account has no default network in Singapore. Ask your IT team for two or more subnets with internet access and a security group that allows outbound HTTPS. Put them in setup.env, for example SUBNETS=subnet-aaa,subnet-bbb and SECURITY_GROUP=sg-xxx, then run bash bin/deploy.sh again."
fi
# shellcheck disable=SC2086
aws ec2 describe-subnets --subnet-ids ${SUBNETS//,/ } >/dev/null 2>&1 \
  || need "a subnet in setup.env (${SUBNETS}) doesn't exist in Singapore. Fix setup.env, then run bash bin/deploy.sh again."
write_env
echo "  subnets ${SUBNETS}; security group ${SECURITY_GROUP}"

echo "Workflow package"
if ! out="$(python3 production/cloud-pipeline/build_workflow_zip.py cloud37-variant-workflow.zip 2>&1)"; then
  need "building the workflow package failed; check your internet connection, then run bash bin/deploy.sh again.
$(tail -n 3 <<<"$out")"
fi
grep -q 'content matches the validated HealthOmics workflow' <<<"$out" \
  || need "the workflow package doesn't match the validated version. Download the repository ZIP again, then run bash bin/deploy.sh."
echo "  cloud37-variant-workflow.zip matches the validated workflow"

# Start the rest in its own session, so it keeps running if Kiro or the terminal closes.
nohup python3 -c '
import os
try:
    os.setsid()
except OSError:
    pass
os.execvp("bash", ["bash", "production/cloud37/bootstrap.sh"])
' > /dev/null 2>&1 < /dev/null &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  alive bootstrap.lock && break
  sleep 1
done
alive bootstrap.lock || need "setup didn't start. Run bash bin/status.sh to see why."
echo
echo "STARTED: setup is running in the background and takes about 30 minutes."
echo "Check progress with: bash bin/status.sh --wait"
