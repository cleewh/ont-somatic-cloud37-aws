#!/usr/bin/env bash
# Copy one pair's BAM files from this computer into the pipeline bucket, where
# bin/start-run.sh expects them: s3://<bucket>/inputs/<sample>/tumor1.bam, tumor2.bam, normal.bam
# The upload runs in the background. Files already uploaded (same size) are skipped, so
# running the same command again resumes an upload that stopped.
#
# Usage, from the repository folder:
#   bash bin/upload.sh --sample NAME --tumor FILE [--tumor2 FILE] --normal FILE   start an upload
#   bash bin/upload.sh --sample NAME [--wait]                                     check its progress
source "$(dirname "$0")/_common.sh"
load_setup

usage() {
  cat <<'EOF'
Usage:
  bash bin/upload.sh --sample NAME --tumor FILE [--tumor2 FILE] --normal FILE   start an upload
  bash bin/upload.sh --sample NAME [--wait]                                     check its progress
EOF
}

SAMPLE="" TUMOR="" TUMOR2="" NORMAL="" WAIT=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --wait) WAIT=yes; shift; continue ;;
  esac
  [[ $# -ge 2 ]] || { usage; need "$1 needs a value."; }
  case "$1" in
    --sample) SAMPLE="$2" ;;
    --tumor)  TUMOR="$2" ;;
    --tumor2) TUMOR2="$2" ;;
    --normal) NORMAL="$2" ;;
    *) usage; need "unknown option $1." ;;
  esac
  shift 2
done
[[ -n "$SAMPLE" ]] || { usage; need "--sample is required."; }
[[ "$SAMPLE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$ ]] \
  || need "sample name '${SAMPLE}' can only use letters, numbers, - and _ (up to 40 characters)."

DEST="s3://${BUCKET}/inputs/${SAMPLE}"
LOG="uploads/${SAMPLE}.log" PIDF="uploads/${SAMPLE}.pid"
mkdir -p uploads

report() {
  if alive "$PIDF"; then
    echo "RUNNING: uploading ${SAMPLE} to ${DEST}/ (started $(hours_since "$(sed -n 's/^started //p' "$LOG")") h ago):"
    grep -E '^(uploading|uploaded|skipped)' "$LOG" | sed 's/^/  /'
    echo "Check again with: bash bin/upload.sh --sample ${SAMPLE} --wait"
  elif grep -q '^== upload complete ==' "$LOG"; then
    local t2=""
    if grep -q -E '^(uploaded|skipped) tumor2\.bam' "$LOG"; then t2=" --tumor2 ${DEST}/tumor2.bam"; fi
    echo "DONE: ${SAMPLE}'s files are in ${DEST}/"
    echo "Next, start the run, using your data's basecaller model (SETUP.md section 4.2):"
    echo "  bash bin/start-run.sh --sample ${SAMPLE} --tumor ${DEST}/tumor1.bam${t2} --normal ${DEST}/normal.bam --model dna_r10.4.1_e8.2_400bps_sup@v4.2.0"
  else
    echo "FAILED: the upload stopped before it finished:"
    tail -n 4 "$LOG" | sed 's/^/  /'
    echo "Run the same upload command again; files already uploaded are skipped."
    return 1
  fi
}

# No files given: report on the upload for this sample.
if [[ -z "${TUMOR}${TUMOR2}${NORMAL}" ]]; then
  [[ -f "$LOG" ]] || need "no upload found for ${SAMPLE}. Start one with: bash bin/upload.sh --sample ${SAMPLE} --tumor FILE [--tumor2 FILE] --normal FILE"
  if [[ "$WAIT" == yes ]]; then wait_for "$PIDF"; fi
  report
  exit 0
fi

if alive "$PIDF"; then
  echo "An upload for ${SAMPLE} is already running."
  report
  exit 0
fi
[[ -n "$TUMOR" && -n "$NORMAL" ]] || { usage; need "--tumor and --normal are required to start an upload."; }
files=("$TUMOR" tumor1.bam)
[[ -z "$TUMOR2" ]] || files+=("$TUMOR2" tumor2.bam)
files+=("$NORMAL" normal.bam)
for (( i = 0; i < ${#files[@]}; i += 2 )); do
  [[ -f "${files[i]}" ]] || need "file not found: ${files[i]}"
  [[ "${files[i]}" == *.bam ]] || need "${files[i]} isn't a .bam file."
done

nohup bash -c '
bucket="$1" prefix="$2"; shift 2
echo "started $(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
while [[ $# -gt 0 ]]; do
  src="$1" name="$2"; shift 2
  size="$(python3 -c "import os, sys; print(os.path.getsize(sys.argv[1]))" "$src")"
  have="$(aws s3api head-object --bucket "$bucket" --key "$prefix/$name" --query ContentLength --output text 2>/dev/null || true)"
  if [[ "$have" == "$size" ]]; then echo "skipped $name (already uploaded)"; continue; fi
  echo "uploading $name from $src ($(( size / 1000000000 )) GB)"
  aws s3 cp --only-show-errors "$src" "s3://$bucket/$prefix/$name" || { echo "ERROR: uploading $src failed"; exit 1; }
  echo "uploaded $name"
done
echo "== upload complete =="
' _ "$BUCKET" "inputs/${SAMPLE}" "${files[@]}" > "$LOG" 2>&1 < /dev/null &
echo $! > "$PIDF"
sleep 2
echo "STARTED: uploading ${SAMPLE}'s files to ${DEST}/ in the background."
echo "Check progress with: bash bin/upload.sh --sample ${SAMPLE} --wait"
