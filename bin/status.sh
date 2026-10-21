#!/usr/bin/env bash
# Report setup progress: RUNNING, READY or FAILED.
#
# Usage, from the repository folder:  bash bin/status.sh [--wait]
#   --wait  if setup is still running, wait up to 90 seconds for it to finish first
source "$(dirname "$0")/_common.sh"
load_setup
if [[ "${1:-}" == --wait ]]; then wait_for bootstrap.lock; fi

if alive bootstrap.lock; then
  echo "RUNNING: setup is in progress; it takes about 30 minutes in total. Latest:"
  tail -n 3 bootstrap.log | sed 's/^/  /'
  exit 0
fi
[[ -f bootstrap.log ]] || need "setup hasn't been started. Run: bash bin/deploy.sh"
if ! grep -q '^== cloud37 bootstrap complete ==' bootstrap.log; then
  echo "FAILED: setup stopped before it finished. The end of bootstrap.log:"
  tail -n 12 bootstrap.log | sed 's/^/  /'
  echo "Find the message in SETUP.md section 5. To try again, run: bash bin/deploy.sh"
  exit 1
fi

# Setup reported success; confirm that every part is in place.
problems=()
for s in cloud37-build cloud37-prereqs cloud37; do
  st="$(aws cloudformation describe-stacks --stack-name "$s" --query 'Stacks[0].StackStatus' \
          --output text 2>/dev/null || echo MISSING)"
  case "$st" in CREATE_COMPLETE|UPDATE_COMPLETE) ;; *) problems+=("stack $s is $st") ;; esac
done
wf="$(aws omics list-workflows --name cloud37-variant-caller --query 'items[0].status' --output text 2>/dev/null || true)"
[[ "$wf" == ACTIVE ]] || problems+=("the HealthOmics workflow isn't active (${wf:-missing})")
ref="$(aws s3api head-object --bucket "$BUCKET" --key inputs/references/GRCh38_no_alt_analysis_set.fna \
         --query ContentLength --output text 2>/dev/null || true)"
[[ "$ref" == 3144230986 ]] || problems+=("the reference genome is missing from s3://${BUCKET}/inputs/references/")
[[ "$(stack_output cloud37 StateMachineArn)" == arn:* ]] || problems+=("the pipeline's state machine wasn't found")
if (( ${#problems[@]} )); then
  echo "FAILED: setup finished, but:"
  printf '  - %s\n' "${problems[@]}"
  echo "To fix it, run: bash bin/deploy.sh"
  exit 1
fi

echo "READY: the pipeline is set up in Asia Pacific (Singapore)."
echo "  Your bucket: s3://${BUCKET}"
limit="$(vcpu_limit)"
if [[ -n "$limit" ]] && (( limit < 128 )); then
  echo "  NOTE: your EC2 limit is ${limit} vCPUs. Runs need 128 and won't start until AWS"
  echo "        approves the increase (SETUP.md section 1, step 5)."
fi
echo "Next: upload your BAM files and start a run (SETUP.md section 4)."
