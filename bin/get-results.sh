#!/usr/bin/env bash
# Download a finished run's results (VCFs, methylation, structural variants and reports)
# into results/<run name>/ in this folder. BAM and CRAM files stay in S3.
# The download runs in the background: run the same command again to see its progress.
#
# Usage, from the repository folder:  bash bin/get-results.sh RUN_NAME [--wait]
#   --wait  if the download is still running, wait up to 90 seconds before reporting
source "$(dirname "$0")/_common.sh"
load_setup
NAME="${1:-}"
[[ -n "$NAME" && "$NAME" != -* ]] \
  || need "give the run name, for example: bash bin/get-results.sh SAMPLE1-20261021-0930"
DEST="results/${NAME}" LOG="results/${NAME}.download.log" PIDF="results/${NAME}.download.pid"
mkdir -p results
if [[ "${2:-}" == --wait ]]; then wait_for "$PIDF"; fi

if alive "$PIDF"; then
  echo "RUNNING: downloading to ${DEST}/ ($(du -sh "$DEST" 2>/dev/null | cut -f1) so far). Run this command again to check."
  exit 0
fi
if [[ -d "$DEST" && -f "$LOG" ]] && grep -q '^== download complete ==' "$LOG"; then
  echo "DONE: $(find "$DEST" -type f | wc -l | tr -d ' ') files ($(du -sh "$DEST" | cut -f1)) in ${DEST}/"
  echo "Main results:"
  find "$DEST" -type f \( -name '*.vcf.gz' -o -name '*report.html' \) ! -path '*/het_snps/*' | sort | sed 's/^/  /'
  exit 0
fi

manifest="$(aws s3 cp "s3://${BUCKET}/outputs/${NAME}/manifest.json" - 2>/dev/null || true)"
RUN="$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read() or "{}").get("healthomics", {}).get("run_id") or "")' <<<"$manifest")"
[[ -n "$RUN" ]] || need "run ${NAME} has no results yet. Check it with: bash bin/run-status.sh ${NAME}"
st="$(aws omics get-run --id "$RUN" --query status --output text)"
[[ "$st" == COMPLETED ]] \
  || need "run ${NAME} hasn't finished (variant calling is ${st}). Check it with: bash bin/run-status.sh ${NAME}"
SRC="s3://${BUCKET}/outputs/${NAME}/${RUN}/definition/output/"

if [[ -f "$LOG" ]]; then
  echo "The last download stopped before it finished:"
  tail -n 3 "$LOG" | sed 's/^/  /'
  echo "Continuing it."
fi
nohup bash -c 'aws s3 sync --only-show-errors "$1" "$2" \
    --exclude "*.bam" --exclude "*.bam.bai" --exclude "*.cram" --exclude "*.crai" \
  && echo "== download complete =="' _ "$SRC" "$DEST/" > "$LOG" 2>&1 < /dev/null &
echo $! > "$PIDF"
echo "STARTED: downloading the results of ${NAME} to ${DEST}/ (about 10 GB at full coverage)."
echo "Run this command again to check progress; it prints DONE when it's finished."
