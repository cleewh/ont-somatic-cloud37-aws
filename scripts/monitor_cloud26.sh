#!/usr/bin/env bash
# One-shot status for the cloud26 run: run status, stage progress, the published
# split manifest (the cloud26-specific validation), and eval shard stats vs cloud25.
RUN="${1:-8384814}"
REGION=ap-southeast-1
OUTP="s3://ont-lrs-somatic-poc-apse1-687677765589/outputs/colo829-cloud26-20260712T1316Z"

echo "=== run $RUN status ==="
aws omics get-run --id "$RUN" --region "$REGION" \
  --query '{status:status,start:startTime,stop:stopTime}' --output json

echo "=== task status counts ==="
aws omics list-run-tasks --id "$RUN" --region "$REGION" --max-results 1000 --output text \
  --query 'items[*].status' 2>/dev/null | tr '\t' '\n' | sort | uniq -c

echo "=== key stage progress (merge / split / eval) ==="
aws omics list-run-tasks --id "$RUN" --region "$REGION" --max-results 1000 --output text \
  --query 'items[?contains(name,`merge_tumor`)||contains(name,`split_candidates`)||contains(name,`mosdepth_split`)||contains(name,`ingress_merged`)].[status,name]' \
  2>/dev/null | tr '\t' ' ' | sort | uniq -c

echo "=== eval shard count + status (cloud25 had 8539) ==="
aws omics list-run-tasks --id "$RUN" --region "$REGION" --max-results 1000 --output text \
  --query 'items[?contains(name,`evaluate_candidates`)].status' 2>/dev/null \
  | tr '\t' '\n' | sort | uniq -c

echo "=== published split manifest (cloud26 self-tuning readout) ==="
if aws s3 ls "$OUTP/clairs_split/clairs_split_manifest.tsv" --region "$REGION" >/dev/null 2>&1; then
  aws s3 cp "$OUTP/clairs_split/clairs_split_manifest.tsv" /tmp/cloud26_manifest.tsv --region "$REGION" >/dev/null 2>&1
  echo "  (contig  n_candidates  W  budget  n_shards  p  DSAT  k  target_min)"
  column -t /tmp/cloud26_manifest.tsv 2>/dev/null || cat /tmp/cloud26_manifest.tsv
  echo "--- totals ---"
  awk -F'\t' 'NR>1{nc+=$2; W+=$3; ns+=$5} END{printf "total candidates=%d  total W=%.3e  total shards=%d  (budget=%s, target=%s min)\n", nc, W, ns, $4, $9}' /tmp/cloud26_manifest.tsv
else
  echo "  not published yet (publishes after split_candidates_by_depth completes; run completion publishes final outputs)."
fi
