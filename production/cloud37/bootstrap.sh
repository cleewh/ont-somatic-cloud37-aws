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
# Prereqs on the machine running this: bash, awscli v2, python3 (or zip). Docker is only
# needed for BUILD_MODE=local. Auth is your ambient AWS credentials.
# Safe to re-run: finished steps are skipped and unchanged stacks are left alone.
#
# Normally started by `bash bin/deploy.sh` (see SETUP.md), which runs it in the background.
# Direct use, from the repository folder:
#   bash production/cloud37/bootstrap.sh [REGION] [BUCKET] [WORKFLOW_ZIP] [REFERENCE_SOURCE_S3_PREFIX]
#
# With no arguments it reads REGION, BUCKET, SUBNETS and SECURITY_GROUP from setup.env and
# uses cloud37-variant-workflow.zip; bin/deploy.sh writes both. Arguments override setup.env.
# Progress goes to bootstrap.log (the previous run's log is kept as bootstrap.previous.log).
#
# REFERENCE_SOURCE_S3_PREFIX (optional): an s3:// prefix holding your own
# GRCh38_no_alt_analysis_set.fna and .fna.fai. Default: the public GIAB copy of the
# GRCh38 no-alt analysis set (GCA_000001405.15), the reference this pipeline was validated on.
set -euo pipefail

# On Windows this runs in Git Bash with the Windows AWS CLI, which ends its output lines with
# \r\n. Drop the \r so values compare correctly (`aws s3 cp` can stream file contents, so
# it's left alone), and pass CloudWatch log group names (/aws/...) through unchanged.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    aws() {
      if [[ "${1:-}" == s3 && "${2:-}" == cp ]]; then command aws "$@"; return; fi
      command aws "$@" | tr -d '\r'
      return "${PIPESTATUS[0]}"
    }
    export MSYS2_ARG_CONV_EXCL="/aws/"
    ;;
esac
# Python, under whichever name it's installed (on Windows: python or py -3).
PYTHON=python3
for p in python3 python "py -3"; do
  if $p -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then PYTHON="$p"; break; fi
done

# One copy at a time; bin/deploy.sh and bin/status.sh read this lock file. A lock left by a
# copy that was stopped (for example by a restart) is ignored, even if its process number
# now belongs to another program.
LOCK=bootstrap.lock
lock_pid="$(cat "$LOCK" 2>/dev/null || true)"
lock_cmd=""
if [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
  if [[ -r "/proc/${lock_pid}/cmdline" ]]; then
    lock_cmd="$(tr '\0' ' ' < "/proc/${lock_pid}/cmdline" 2>/dev/null || true)"
  else
    lock_cmd="$(ps -ww -o command= -p "$lock_pid" 2>/dev/null || true)"
  fi
fi
if [[ "$lock_cmd" == *bootstrap.sh* ]]; then
  echo "bootstrap.sh is already running (process ${lock_pid}). Check progress with: bash bin/status.sh" >&2
  exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

if [[ -f bootstrap.log ]]; then mv -f bootstrap.log bootstrap.previous.log; fi
exec > >(tee bootstrap.log) 2>&1
echo "== $(date -u '+%Y-%m-%d %H:%M:%S') UTC =="

if [[ -f setup.env ]]; then source ./setup.env; fi
REGION="${1:-${AWS_REGION:-}}"
BUCKET="${2:-${BUCKET:-}}"
WF_ZIP="${3:-cloud37-variant-workflow.zip}"
REF_SRC="${4:-}"

# Check every input first, so a missing value fails now rather than 30 minutes in.
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -n "$REGION" && -n "$BUCKET" ]] || fail "region and bucket are not set; run bash bin/deploy.sh (it writes setup.env), or pass them as arguments"
[[ "${SUBNETS:-}" == subnet-* ]] || fail "SUBNETS is not set to subnet IDs (subnet-...); run bash bin/deploy.sh"
[[ "${SECURITY_GROUP:-}" == sg-* ]] || fail "SECURITY_GROUP is not set to a security group ID (sg-...); run bash bin/deploy.sh"
[[ "$WF_ZIP" == s3://* || -f "$WF_ZIP" ]] || fail "workflow ZIP '$WF_ZIP' not found; run bash bin/deploy.sh"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCT}.dkr.ecr.${REGION}.amazonaws.com"
PREFIX="docker-hub"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BUILD_MODE: "codebuild" (default; cloud-side, no local Docker, arch-independent)
#             "local"     (build on this machine; requires Docker with amd64 support)
BUILD_MODE="${BUILD_MODE:-codebuild}"
echo "== cloud37 bootstrap : account ${ACCT} region ${REGION} bucket ${BUCKET} build_mode ${BUILD_MODE} =="

# Each alignment runs on a 32-vCPU instance and a pair aligns 3 inputs at once, so the
# account's On-Demand vCPU quota decides whether (and how fast) Batch jobs can start.
VCPU_QUOTA="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --region "$REGION" --query 'Quota.Value' --output text 2>/dev/null || true)"
if [[ "$VCPU_QUOTA" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( ${VCPU_QUOTA%.*} < 96 )); then
  echo "   WARNING: this account can run only ${VCPU_QUOTA%.*} On-Demand vCPUs in ${REGION}."
  echo "            Alignment needs 32 per job and 96 for a pair to align in parallel; below 32"
  echo "            jobs never start. In the Service Quotas console, raise 'Running On-Demand"
  echo "            Standard (A, C, D, H, I, M, R, T, Z) instances' to at least 128. Setup continues."
fi

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
    # shellcheck disable=SC2086
    $PYTHON - "$tmp_zip" "$SCRIPT_DIR" <<'PY'
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
    --no-fail-on-empty-changeset \
    --region "$REGION" \
    --parameter-overrides "Bucket=${BUCKET}" "BuildContextKey=${ctx_key}" "EcrRepositoryPrefix=${PREFIX}"

  local proj; proj="$(aws cloudformation describe-stacks --stack-name cloud37-build --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='BuildProjectName'].OutputValue" --output text)"
  # The build also stages the default reference (step 3) inside AWS, so the 3.1 GB upload
  # doesn't depend on this machine's network. Skipped when you supply your own reference.
  local stage_ref=yes
  if [[ -n "$REF_SRC" ]]; then stage_ref=no; fi
  local bid st misses=0
  # If an earlier attempt left a build running, wait for that one instead of starting another.
  bid="$(aws codebuild list-builds-for-project --project-name "$proj" --region "$REGION" \
           --query 'ids[0]' --output text 2>/dev/null || true)"
  if [[ "$bid" == "${proj}:"* ]] && [[ "$(aws codebuild batch-get-builds --ids "$bid" --region "$REGION" \
         --query 'builds[0].buildStatus' --output text 2>/dev/null || true)" == IN_PROGRESS ]]; then
    echo "   build ${bid} from an earlier attempt is still running; waiting for it"
  else
    echo "   starting CodeBuild project ${proj} (mirrors 8 containers, builds align image, stages reference: ${stage_ref})"
    bid="$(aws codebuild start-build --project-name "$proj" --region "$REGION" \
      --environment-variables-override "name=STAGE_REFERENCE,value=${stage_ref},type=PLAINTEXT" \
      --query 'build.id' --output text)"
  fi
  echo "   build id: ${bid} - waiting for completion (about 20 minutes)..."
  while true; do
    # A dropped connection must not abort setup: the build keeps running in AWS, so keep
    # polling through errors and give up only after ~10 minutes without an answer.
    if ! st="$(aws codebuild batch-get-builds --ids "$bid" --region "$REGION" \
                 --query 'builds[0].buildStatus' --output text 2>/dev/null)"; then
      misses=$((misses + 1))
      if (( misses >= 30 )); then
        echo "   ERROR: no answer from AWS for 10 minutes while waiting for CodeBuild; check your" >&2
        echo "          connection and re-run bootstrap (finished work is skipped)." >&2
        exit 1
      fi
      sleep 20; continue
    fi
    misses=0
    case "$st" in
      SUCCEEDED) echo "   CodeBuild SUCCEEDED"; break ;;
      IN_PROGRESS) sleep 20 ;;
      *)
        echo "   ERROR: CodeBuild ${st}. The end of the build log:"
        local lg_group lg_stream
        read -r lg_group lg_stream <<<"$(aws codebuild batch-get-builds --ids "$bid" --region "$REGION" \
          --query 'builds[0].logs.[groupName,streamName]' --output text 2>/dev/null || true)"
        if [[ -n "${lg_stream:-}" && "$lg_stream" != None ]]; then
          aws logs get-log-events --region "$REGION" --log-group-name "$lg_group" --log-stream-name "$lg_stream" \
            --limit 15 --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/     /' || true
        fi
        echo "   Full log: AWS console > CodeBuild > Build projects > ${proj} > the latest build."
        exit 1 ;;
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
      # Docker Hub rate-limits anonymous pulls; retry before giving up (re-running later also works).
      for i in 1 2 3; do
        docker pull "ontresearch/${name}:${tag}" && break
        [[ $i == 3 ]] && { echo "   ERROR: docker pull failed 3 times (Docker Hub rate limit?); re-run later." >&2; exit 1; }
        echo "   pull failed, retrying in 60s"; sleep 60
      done
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
REF_KEY="inputs/references/GRCh38_no_alt_analysis_set.fna"
REF_BYTES=3144230986   # uncompressed size of the validated GRCh38 no-alt analysis set
present() { aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$REGION" >/dev/null 2>&1; }
if [[ -n "$REF_SRC" ]]; then
  for f in "${REF_KEY##*/}" "${REF_KEY##*/}.fai"; do
    if present "inputs/references/${f}"; then echo "   present: ${f}"; else
      echo "   copy: ${REF_SRC%/}/${f}"
      aws s3 cp "${REF_SRC%/}/${f}" "s3://${BUCKET}/inputs/references/${f}" --region "$REGION"
    fi
  done
else
  # Normally already staged by the CodeBuild run above; this local path covers BUILD_MODE=local.
  GIAB_REF="s3://giab/release/references/GRCh38/GCA_000001405.15_GRCh38_no_alt_analysis_set.fasta.gz"
  if present "$REF_KEY"; then echo "   present: ${REF_KEY##*/}"; else
    echo "   download + decompress the public GIAB copy (0.9 GB in, 3.1 GB to S3; a few minutes)"
    if ! aws s3 cp --no-sign-request --region us-east-1 --only-show-errors "$GIAB_REF" - | gzip -dc \
         | aws s3 cp - "s3://${BUCKET}/${REF_KEY}" --region "$REGION" --expected-size "$REF_BYTES" --only-show-errors; then
      aws s3 rm "s3://${BUCKET}/${REF_KEY}" --region "$REGION" >/dev/null 2>&1 || true
      echo "   ERROR: reference download failed; re-run bootstrap." >&2; exit 1
    fi
    got="$(aws s3api head-object --bucket "$BUCKET" --key "$REF_KEY" --region "$REGION" --query ContentLength --output text)"
    if [[ "$got" != "$REF_BYTES" ]]; then
      aws s3 rm "s3://${BUCKET}/${REF_KEY}" --region "$REGION" >/dev/null
      echo "   ERROR: reference is ${got} bytes, expected ${REF_BYTES}; removed it, re-run bootstrap." >&2; exit 1
    fi
  fi
  if present "${REF_KEY}.fai"; then echo "   present: ${REF_KEY##*/}.fai"; else
    tmp_fai="$(mktemp)"
    aws s3 cp --no-sign-request --region us-east-1 --only-show-errors "${GIAB_REF}.fai" "$tmp_fai"
    aws s3 cp --only-show-errors "$tmp_fai" "s3://${BUCKET}/${REF_KEY}.fai" --region "$REGION"
    rm -f "$tmp_fai"
  fi
fi

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
  --no-fail-on-empty-changeset \
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
  --no-fail-on-empty-changeset \
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

echo "== cloud37 bootstrap complete =="
echo "   State machine: $(aws cloudformation describe-stacks --stack-name cloud37 --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='StateMachineArn'].OutputValue" --output text)"
echo "   Next: bash bin/status.sh, then start a pair (SETUP.md section 4)."
if [[ "$BUILD_MODE" == local ]]; then
  echo "   Run 'docker logout ${ECR}' to remove the cached ECR login."
fi
