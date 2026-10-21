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
rm -f "$PIDF"
start_detached "$LOG" bin/_download_worker.sh "$PIDF" "$SRC" "$DEST/"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if alive "$PIDF" || grep -q '^== download complete ==' "$LOG" 2>/dev/null; then break; fi
  sleep 1
done
if ! alive "$PIDF" && ! grep -q '^== download complete ==' "$LOG" 2>/dev/null; then
  echo "FAILED: the download didn't start:"
  tail -n 4 "$LOG" 2>/dev/null | sed 's/^/  /'
  exit 1
fi
echo "STARTED: downloading the results of ${NAME} to ${DEST}/ (about 10 GB at full coverage)."
echo "Run this command again to check progress; it prints DONE when it's finished."
