#!/usr/bin/env bash
# watch_run.sh — poll HealthOmics run status until terminal.
#
# Usage:
#   ./watch_run.sh <run_id> [poll_interval_seconds]
#
# Defaults:
#   poll_interval_seconds = 60
#   region                = ap-southeast-1
#
# Prints one status line per poll and exits when the run reaches a terminal
# status (COMPLETED, FAILED, or CANCELLED).
#
# Design reference: .kiro/specs/nextflow-poc-on-aws/design.md
#   § "Post-Run Analysis → Terminal-status watcher".

set -euo pipefail

DEFAULT_RUN_ID="3295679"  # colo829-poc-20260704T0552Z-tuned2 (optimization-bundle run)

if [[ $# -lt 1 ]]; then
  RUN_ID="$DEFAULT_RUN_ID"
  echo "no run_id given, defaulting to latest: $RUN_ID"
else
  RUN_ID="$1"
fi
INTERVAL="${2:-60}"
REGION="${AWS_REGION:-ap-southeast-1}"

TERMINAL_REGEX='^(COMPLETED|FAILED|CANCELLED)$'

echo "watching run $RUN_ID in $REGION (poll every ${INTERVAL}s) ..."
while true; do
  status="$(aws omics get-run --id "$RUN_ID" --region "$REGION" --query 'status' --output text)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "$ts  status=$status"
  if [[ "$status" =~ $TERMINAL_REGEX ]]; then
    echo "run $RUN_ID reached terminal status: $status"
    if [[ "$status" != "COMPLETED" ]]; then
      # Print failure/cancellation reason for context.
      aws omics get-run --id "$RUN_ID" --region "$REGION" \
        --query '{status:status,failureReason:failureReason,statusMessage:statusMessage,stopTime:stopTime}' \
        --output json
    fi
    exit 0
  fi
  sleep "$INTERVAL"
done
