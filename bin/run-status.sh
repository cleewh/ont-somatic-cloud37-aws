#!/usr/bin/env bash
# Report a run's progress, or list recent runs when no name is given.
#
# Usage, from the repository folder:  bash bin/run-status.sh [RUN_NAME]
source "$(dirname "$0")/_common.sh"
load_setup
SM="$(stack_output cloud37 StateMachineArn)"
[[ "$SM" == arn:* ]] || need "the pipeline isn't set up. Run: bash bin/deploy.sh"

if [[ $# -eq 0 ]]; then
  echo "Recent runs, newest first (name, alignment stage, start time):"
  aws stepfunctions list-executions --state-machine-arn "$SM" --max-items 10 \
    --query 'executions[].[name,status,startDate]' --output text | sed 's/^/  /'
  echo "Full status of one run: bash bin/run-status.sh RUN_NAME"
  exit 0
fi

NAME="$1"
EXEC="${SM/:stateMachine:/:execution:}:${NAME}"
status="$(aws stepfunctions describe-execution --execution-arn "$EXEC" --query status --output text 2>/dev/null)" \
  || need "there's no run named ${NAME}. List recent runs with: bash bin/run-status.sh"

case "$status" in
RUNNING)
  started="$(aws stepfunctions describe-execution --execution-arn "$EXEC" --query startDate --output text)"
  step="$(aws stepfunctions get-execution-history --execution-arn "$EXEC" --reverse-order --max-items 40 \
            --query 'events[?type==`TaskStateEntered`].stateEnteredEventDetails.name | [0]' --output text)"
  case "$step" in
    MergeTumors) echo "MERGING: combining the two tumor files ($(hours_since "$started") h since the run started; merging takes about 2 hours at full coverage)." ;;
    Aln*)        echo "ALIGNING: aligning the BAM files on AWS Batch ($(hours_since "$started") h so far; about 5 hours at full coverage)." ;;
    *)           echo "STARTING VARIANT CALLING: handing the aligned files to HealthOmics." ;;
  esac
  # Jobs that wait a long time for computers usually mean the EC2 limit is too low.
  cutoff=$(( ($(date +%s) - 900) * 1000 ))
  waiting="$(aws batch list-jobs --job-queue "$(stack_output cloud37 JobQueueName)" --job-status RUNNABLE \
               --query "length(jobSummaryList[?createdAt < \`${cutoff}\`])" --output text 2>/dev/null || true)"
  if [[ "$waiting" =~ ^[1-9] ]]; then
    echo "  NOTE: ${waiting} job(s) have waited more than 15 minutes for computers to start. That usually"
    echo "        means your EC2 limit is too low (SETUP.md section 1, step 5)."
  fi
  ;;
SUCCEEDED)
  manifest="$(aws s3 cp "s3://${BUCKET}/outputs/${NAME}/manifest.json" - 2>/dev/null || true)"
  IFS='|' read -r RUN SAMPLE <<<"$(python3 -c 'import json, sys
m = json.loads(sys.stdin.read() or "{}")
print(m.get("healthomics", {}).get("run_id") or "", m.get("sample_name") or "", sep="|")' <<<"$manifest")"
  [[ -n "$RUN" ]] || need "run ${NAME} has no manifest.json in s3://${BUCKET}/outputs/${NAME}/. Ask Kiro to look at this run's Step Functions execution."
  IFS=$'\t' read -r rst rstart rreason <<<"$(aws omics get-run --id "$RUN" \
      --query '[status,startTime,failureReason]' --output text)"
  case "$rst" in
    PENDING|STARTING) echo "VARIANT CALLING: HealthOmics run ${RUN} is starting." ;;
    RUNNING) echo "VARIANT CALLING: HealthOmics run ${RUN} ($(hours_since "$rstart") h so far; about 9 hours at full coverage)." ;;
    COMPLETED)
      key="outputs/${NAME}/${RUN}/definition/output/${SAMPLE}/snv/vcf/${SAMPLE}_somatic_snv.vcf.gz"
      if aws s3api head-object --bucket "$BUCKET" --key "$key" >/dev/null 2>&1; then
        echo "COMPLETED: results are in s3://${BUCKET}/outputs/${NAME}/${RUN}/definition/output/"
        echo "Download them with: bash bin/get-results.sh ${NAME}"
      else
        echo "COMPLETED WITHOUT RESULTS: HealthOmics finished but made no somatic variant calls."
        echo "  The usual cause is coverage below 20x in the tumor or the normal (SETUP.md section 5)."
      fi
      ;;
    *)
      echo "FAILED: variant calling stopped. HealthOmics run ${RUN} is ${rst}: ${rreason}"
      echo "  Ask Kiro: \"Why did HealthOmics run ${RUN} fail? Read its logs.\""
      exit 1
      ;;
  esac
  ;;
*)
  IFS=$'\t' read -r err cause <<<"$(aws stepfunctions describe-execution --execution-arn "$EXEC" \
      --query '[error,cause]' --output text)"
  echo "FAILED: the alignment stage stopped (${status}): ${err}"
  echo "  ${cause:0:400}"
  echo "  Ask Kiro: \"Why did run ${NAME} fail?\""
  exit 1
  ;;
esac
