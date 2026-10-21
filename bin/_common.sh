# Shared by the scripts in bin/. Not meant to be run on its own.
set -euo pipefail

# The pipeline runs only in Asia Pacific (Singapore).
REGION=ap-southeast-1
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION
# Never open a pager: a waiting pager would leave Kiro's command hanging.
export AWS_PAGER=""

# Work from the repository folder, where setup.env and the logs are kept.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Stop with a message that tells the user what to do.
need() {
  echo
  echo "ACTION NEEDED: $*"
  exit 1
}

# Read the bucket and network that bin/deploy.sh saved in setup.env.
load_setup() {
  [[ -f setup.env ]] || need "the pipeline hasn't been set up from this folder. Run: bash bin/deploy.sh"
  unset BUCKET SUBNETS SECURITY_GROUP
  # shellcheck disable=SC1091
  source ./setup.env
  export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
  [[ -n "${BUCKET:-}" ]] || need "setup.env has no bucket. Run: bash bin/deploy.sh"
}

# One output value of a CloudFormation stack, or nothing.
stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null || true
}

# The account's EC2 On-Demand Standard vCPU limit in Singapore (whole number), or nothing.
vcpu_limit() {
  local v
  v="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
         --query 'Quota.Value' --output text 2>/dev/null || true)"
  if [[ ! "$v" =~ ^[0-9] ]]; then
    v="$(aws service-quotas get-aws-default-service-quota --service-code ec2 --quota-code L-1216C47A \
           --query 'Quota.Value' --output text 2>/dev/null || true)"
  fi
  if [[ "$v" =~ ^[0-9] ]]; then echo "${v%%.*}"; fi
}

# Is the process recorded in pid file $1 still running?
alive() {
  [[ -f "$1" ]] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null
}

# For --wait: give the background task in pid file $1 up to 90 seconds to finish.
wait_for() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9; do
    alive "$1" || return 0
    sleep 10
  done
}

# Hours since an ISO timestamp printed by the AWS CLI, with one decimal.
hours_since() {
  python3 - "$1" <<'PY'
import sys, datetime as d
try:
    t = d.datetime.fromisoformat(sys.argv[1])
    print(f"{(d.datetime.now(d.timezone.utc) - t).total_seconds() / 3600:.1f}")
except Exception:
    print("?")
PY
}
