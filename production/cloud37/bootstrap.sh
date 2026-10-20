#!/usr/bin/env bash
# cloud37 one-time account bootstrap.
# Automates every prerequisite except supplying your own tumor/normal BAMs:
#   1. Mirror the 8 ontresearch/* containers into your ECR (docker-hub/* prefix) and
#      attach the repository policy HealthOmics needs to pull them
#   2. Build + push the align/merge container (cloud37-align)
#   3. Stage the GRCh38 reference genome into your bucket
#   4. Upload the variant-caller workflow definition ZIP
#   5. Deploy the prereqs stack (run role + run group + workflow/version)
#   6. Auto-generate deploy.params.json and deploy the app stack
#
# Prereqs on the machine running this: awscli v2, docker (with buildx for amd64),
# and network access to Docker Hub + GitHub. Auth is your ambient AWS credentials.
#
# Usage:
#   ./bootstrap.sh <REGION> <BUCKET> <WORKFLOW_ZIP_LOCAL_OR_S3> [REFERENCE_SOURCE_S3]
#
# Example:
#   ./bootstrap.sh ap-southeast-1 my-genomics-bucket ./wf-somatic-variation-cloud36.zip
set -euo pipefail

REGION="${1:?REGION required}"
BUCKET="${2:?BUCKET required}"
WF_ZIP="${3:?workflow definition ZIP (local path or s3:// URI) required}"
REF_SRC="${4:-s3://ont-open-data/colo829_2024.03/references}"   # override for your own ref source

ACCT="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCT}.dkr.ecr.${REGION}.amazonaws.com"
PREFIX="docker-hub"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BUILD_MODE: "codebuild" (default; cloud-side, no local Docker, arch-independent)
#             "local"     (build on this machine; requires Docker with amd64 support)
BUILD_MODE="${BUILD_MODE:-codebuild}"
echo "== cloud37 bootstrap : account ${ACCT} region ${REGION} bucket ${BUCKET} build_mode ${BUILD_MODE} =="

# The 8 ontresearch/* containers pinned for wf-somatic-variation v1.5.1 (image:tag).
IMAGES=(
  "wf-somatic-variation:sha5d62edcc2853ce1fd9afc244ff87e65788c4c596"
  "wf-somatic-snp:sha86599ecdb46472d01e0b7c2704683f6aee8a82dd"
  "clairs-to:sha0bed006dfad374401e9410b44d67e6609f7936e9"
  "modkit:shaa7bf2b62946eeb7646b9b9d60b892edfc3b3a52c"
  "dss:sha927196d7e068cc49d5a41bcc3db91b9bdf723e7a"
  "wf-somatic-sv:sha4b941d684b3310e8524ce169da2d358a6631fab0"
  "wf-common:sha72f3517dd994984e0e2da0b97cb3f23f8540be4b"
  "snpeff:sha313729d816872d70b410752001a0e2654eb88807"
)

# HealthOmics only pulls from a private ECR repo whose resource policy grants the
# omics.amazonaws.com service principal; the run role's IAM permissions are not enough.
# Keep in sync with OMICS_POLICY in cloud37-build.yaml.
OMICS_REPO_POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"HealthOmicsAccess","Effect":"Allow","Principal":{"Service":"omics.amazonaws.com"},"Action":["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability"]}]}'

# Attach the HealthOmics pull policy to a mirrored repo if it has none. An existing policy
# is never overwritten; if it lacks HealthOmics access, stop so it can be fixed by hand.
ensure_omics_repo_policy() {
  local repo="$1" pol
  if pol="$(aws ecr get-repository-policy --repository-name "$repo" --region "$REGION" \
              --query policyText --output text 2>&1)"; then
    case "$pol" in
      *omics.amazonaws.com*) echo "   policy ok: ${repo}" ;;
      *) echo "   ERROR: ${repo} has a repository policy without HealthOmics (omics.amazonaws.com) pull access." >&2
         echo "          Add the OMICS_REPO_POLICY statement to it and re-run." >&2
         return 1 ;;
    esac
  else
    case "$pol" in
      *RepositoryPolicyNotFoundException*)
        aws ecr set-repository-policy --repository-name "$repo" --region "$REGION" \
          --policy-text "$OMICS_REPO_POLICY" >/dev/null
        echo "   policy set (HealthOmics pull): ${repo}" ;;
      *) echo "$pol" >&2; return 1 ;;
    esac
  fi
}

ecr_login() {
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR"
}

build_codebuild() {
  echo "-- [1-2/6] cloud-side build via CodeBuild (no local Docker) --"
  local ctx_key="workflow-artifacts/cloud37-build-context.zip"
  local tmp_dir; tmp_dir="$(mktemp -d)"      # dir, not a pre-created file (zip rejects existing empty file)
  local tmp_zip="${tmp_dir}/ctx.zip"
  # Flatten Dockerfile + job scripts into the ZIP root (build context).
  if command -v zip >/dev/null 2>&1; then
    ( cd "$SCRIPT_DIR" && zip -j -q "$tmp_zip" Dockerfile align_job.sh merge_job.sh )
  else
    python3 - "$tmp_zip" "$SCRIPT_DIR" <<'PY'
import sys, zipfile, os
z, d = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as f:
    for n in ("Dockerfile", "align_job.sh", "merge_job.sh"):
        f.write(os.path.join(d, n), n)
PY
  fi
  aws s3 cp "$tmp_zip" "s3://${BUCKET}/${ctx_key}" --region "$REGION"
  rm -rf "$tmp_dir"

  aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/cloud37-build.yaml" \
    --stack-name cloud37-build \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --parameter-overrides "Bucket=${BUCKET}" "BuildContextKey=${ctx_key}" "EcrRepositoryPrefix=${PREFIX}"

  local proj; proj="$(aws cloudformation describe-stacks --stack-name cloud37-build --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='BuildProjectName'].OutputValue" --output text)"
  echo "   starting CodeBuild project ${proj} (mirrors 8 containers + builds align image)"
  local bid; bid="$(aws codebuild start-build --project-name "$proj" --region "$REGION" \
    --query 'build.id' --output text)"
  echo "   build id: ${bid} - waiting for completion..."
  while true; do
    local st; st="$(aws codebuild batch-get-builds --ids "$bid" --region "$REGION" \
      --query 'builds[0].buildStatus' --output text)"
    case "$st" in
      SUCCEEDED) echo "   CodeBuild SUCCEEDED"; break ;;
      IN_PROGRESS) sleep 20 ;;
      *) echo "   CodeBuild ${st} - see console logs for project ${proj}"; exit 1 ;;
    esac
  done
}

build_local() {
  echo "-- [1/6] mirroring ${#IMAGES[@]} ontresearch/* containers to ECR ${ECR}/${PREFIX}/ (local Docker) --"
  ecr_login
  for img in "${IMAGES[@]}"; do
    name="${img%%:*}"; tag="${img##*:}"
    repo="${PREFIX}/ontresearch/${name}"
    aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
      || aws ecr create-repository --repository-name "$repo" --region "$REGION" \
           --image-scanning-configuration scanOnPush=true >/dev/null
    ensure_omics_repo_policy "$repo"
    if aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$tag" \
         --region "$REGION" >/dev/null 2>&1; then
      echo "   already mirrored: ${repo}:${tag}"
    else
      echo "   pull/push: ontresearch/${name}:${tag}"
      docker pull "ontresearch/${name}:${tag}"
      docker tag  "ontresearch/${name}:${tag}" "${ECR}/${repo}:${tag}"
      docker push "${ECR}/${repo}:${tag}"
    fi
  done
  echo "-- [2/6] build + push align/merge container (cloud37-align) --"
  aws ecr describe-repositories --repository-names cloud37-align --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name cloud37-align --region "$REGION" \
         --image-scanning-configuration scanOnPush=true >/dev/null
  docker build --platform linux/amd64 -t "${ECR}/cloud37-align:latest" "$SCRIPT_DIR"
  docker push "${ECR}/cloud37-align:latest"
}

if [[ "$BUILD_MODE" == "local" ]]; then build_local; else build_codebuild; fi

echo "-- [3/6] stage reference genome to s3://${BUCKET}/inputs/references/ --"
for f in GRCh38_no_alt_analysis_set.fna GRCh38_no_alt_analysis_set.fna.fai GRCh38_no_alt_analysis_set.dict; do
  if aws s3 ls "s3://${BUCKET}/inputs/references/${f}" --region "$REGION" >/dev/null 2>&1; then
    echo "   present: ${f}"
  else
    echo "   copy: ${f}"
    aws s3 cp "${REF_SRC}/${f}" "s3://${BUCKET}/inputs/references/${f}" --region "$REGION"
  fi
done

echo "-- [4/6] upload workflow definition ZIP --"
WF_ZIP_S3="s3://${BUCKET}/workflow-artifacts/cloud37-variant-definition.zip"
if [[ "$WF_ZIP" == s3://* ]]; then
  aws s3 cp "$WF_ZIP" "$WF_ZIP_S3" --region "$REGION"
else
  aws s3 cp "$WF_ZIP" "$WF_ZIP_S3" --region "$REGION"
fi

echo "-- [5/6] deploy prereqs stack (run role + run group + workflow/version) --"
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/cloud37-prereqs.yaml" \
  --stack-name cloud37-prereqs \
  --capabilities CAPABILITY_IAM \
  --region "$REGION" \
  --parameter-overrides \
      "Bucket=${BUCKET}" \
      "WorkflowDefinitionUri=${WF_ZIP_S3}" \
      "EcrRepositoryPrefix=${PREFIX}"

get_out() { aws cloudformation describe-stacks --stack-name cloud37-prereqs --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
RUN_ROLE_ARN="$(get_out OmicsRunRoleArn)"
RUN_GROUP_ID="$(get_out OmicsRunGroupId)"
WORKFLOW_ID="$(get_out OmicsWorkflowId)"
VERSION_NAME="$(get_out OmicsVariantVersionName)"
echo "   run role : ${RUN_ROLE_ARN}"
echo "   run group: ${RUN_GROUP_ID}"
echo "   workflow : ${WORKFLOW_ID} / ${VERSION_NAME}"

echo "-- [6/6] generate deploy.params.json and deploy app stack --"
echo "   NOTE: fill in your VPC Subnets + SecurityGroup below (customer network)."
: "${SUBNETS:?set SUBNETS env var (comma-separated subnet ids) before this step}"
: "${SECURITY_GROUP:?set SECURITY_GROUP env var (sg id) before this step}"

cat > "${SCRIPT_DIR}/deploy.params.json" <<JSON
[
  {"ParameterKey": "Bucket",                  "ParameterValue": "${BUCKET}"},
  {"ParameterKey": "AlignImageUri",           "ParameterValue": "${ECR}/cloud37-align:latest"},
  {"ParameterKey": "Subnets",                 "ParameterValue": "${SUBNETS}"},
  {"ParameterKey": "SecurityGroup",           "ParameterValue": "${SECURITY_GROUP}"},
  {"ParameterKey": "OmicsWorkflowId",         "ParameterValue": "${WORKFLOW_ID}"},
  {"ParameterKey": "OmicsVariantVersionName", "ParameterValue": "${VERSION_NAME}"},
  {"ParameterKey": "OmicsRunRoleArn",         "ParameterValue": "${RUN_ROLE_ARN}"},
  {"ParameterKey": "OmicsRunGroupId",         "ParameterValue": "${RUN_GROUP_ID}"}
]
JSON

aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/cloud37-stack.yaml" \
  --stack-name cloud37 \
  --capabilities CAPABILITY_IAM \
  --region "$REGION" \
  --parameter-overrides \
      "Bucket=${BUCKET}" \
      "AlignImageUri=${ECR}/cloud37-align:latest" \
      "Subnets=${SUBNETS}" \
      "SecurityGroup=${SECURITY_GROUP}" \
      "OmicsWorkflowId=${WORKFLOW_ID}" \
      "OmicsVariantVersionName=${VERSION_NAME}" \
      "OmicsRunRoleArn=${RUN_ROLE_ARN}" \
      "OmicsRunGroupId=${RUN_GROUP_ID}"

echo "== cloud37 bootstrap complete. Start a pair with: =="
echo "   aws stepfunctions start-execution --state-machine-arn <cloud37 StateMachineArn> \\"
echo "     --input file://pair-input.json --region ${REGION}"
echo "   (docker logout ${ECR} to scrub the cached ECR token)"
