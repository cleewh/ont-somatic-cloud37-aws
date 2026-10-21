#!/usr/bin/env bash
# Start the pipeline for one tumor-normal pair. Checks the inputs first.
#
# Usage, from the repository folder:
#   bash bin/start-run.sh --sample NAME --tumor S3_URI [--tumor2 S3_URI] --normal S3_URI \
#                         [--model BASECALLER_MODEL] [--name RUN_NAME]
source "$(dirname "$0")/_common.sh"
load_setup

usage() {
  cat <<'EOF'
Usage:
  bash bin/start-run.sh --sample NAME --tumor S3_URI [--tumor2 S3_URI] --normal S3_URI \
                        [--model BASECALLER_MODEL] [--name RUN_NAME]

  --sample  sample name used in the output file names: letters, numbers, - and _
  --tumor   tumor BAM in your bucket, e.g. s3://<bucket>/inputs/SAMPLE1/tumor1.bam
  --tumor2  second tumor BAM, only when the tumor was sequenced on two flow cells
  --normal  normal BAM in your bucket
  --model   basecaller model of the data (default dna_r10.4.1_e8.2_400bps_sup@v4.2.0)
  --name    a name for this run, unique per run (default <sample>-<date>-<time>)
EOF
}

SAMPLE="" TUMOR="" TUMOR2="" NORMAL="" NAME=""
MODEL="dna_r10.4.1_e8.2_400bps_sup@v4.2.0"
while [[ $# -gt 0 ]]; do
  case "$1" in -h|--help) usage; exit 0 ;; esac
  [[ $# -ge 2 ]] || { usage; need "$1 needs a value."; }
  case "$1" in
    --sample) SAMPLE="$2" ;;
    --tumor)  TUMOR="$2" ;;
    --tumor2) TUMOR2="$2" ;;
    --normal) NORMAL="$2" ;;
    --model)  MODEL="$2" ;;
    --name)   NAME="$2" ;;
    *) usage; need "unknown option $1." ;;
  esac
  shift 2
done
[[ -n "$SAMPLE" && -n "$TUMOR" && -n "$NORMAL" ]] || { usage; need "--sample, --tumor and --normal are required."; }
[[ "$SAMPLE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$ ]] \
  || need "sample name '${SAMPLE}' can only use letters, numbers, - and _ (up to 40 characters)."

# The workflow rejects models outside its list, so check now rather than hours into the run.
models="$(python3 - <<'PY'
import json
schema = json.load(open("production/cloud-pipeline/nextflow_schema.json"))
for group in schema.get("definitions", schema.get("$defs", {})).values():
    p = group.get("properties", {}).get("override_basecaller_cfg")
    if p:
        print("\n".join(p.get("enum", [])))
PY
)"
grep -qxF -- "$MODEL" <<<"$models" \
  || need "basecaller model '${MODEL}' isn't supported by this workflow version. Use your data's model; for a newer sup model, use dna_r10.4.1_e8.2_400bps_sup@v4.2.0. Supported models:
$(sed 's/^/  /' <<<"$models")"

echo "Checking the input files"
check_bam() {   # $1 = option name, $2 = S3 URI
  local size
  [[ "$2" == "s3://${BUCKET}/"* ]] \
    || need "$1 must be a file in your pipeline bucket, s3://${BUCKET}/. Upload it first (SETUP.md section 4.1)."
  [[ "$2" == *.bam ]] || need "$1 must be a .bam file: $2"
  size="$(aws s3api head-object --bucket "$BUCKET" --key "${2#s3://${BUCKET}/}" \
            --query ContentLength --output text 2>/dev/null)" || need "$1 file not found: $2"
  echo "  $1 $2 ($(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1e9 }') GB)"
}
check_bam --tumor "$TUMOR"
[[ -z "$TUMOR2" ]] || check_bam --tumor2 "$TUMOR2"
check_bam --normal "$NORMAL"

NAME="${NAME:-${SAMPLE}-$(date -u +%Y%m%d-%H%M)}"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$ ]] \
  || need "run name '${NAME}' can only use letters, numbers, - and _ (up to 80 characters)."
SM="$(stack_output cloud37 StateMachineArn)"
[[ "$SM" == arn:* ]] || need "the pipeline isn't set up. Run: bash bin/deploy.sh"
used="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "outputs/${NAME}/" --max-items 1 \
          --query 'Contents[0].Key' --output text 2>/dev/null || true)"
if [[ -n "$used" && "$used" != None ]] \
   || aws stepfunctions describe-execution --execution-arn "${SM/:stateMachine:/:execution:}:${NAME}" >/dev/null 2>&1; then
  need "there's already a run named ${NAME}. Choose another name with --name."
fi

limit="$(vcpu_limit)"
if [[ -n "$limit" ]] && (( limit < 32 )); then
  need "your EC2 limit in Singapore is ${limit} vCPUs, so alignment can't start (it needs 32 per file and 128 in total). Wait until AWS approves the increase (SETUP.md section 1, step 5), then run this again."
fi

mkdir -p runs
python3 - "$SAMPLE" "$TUMOR" "$TUMOR2" "$NORMAL" "$MODEL" "$BUCKET" "$NAME" > "runs/${NAME}.json" <<'PY'
import json, sys
sample, tumor, tumor2, normal, model, bucket, name = sys.argv[1:]
pair = {
    "sample_name": sample,
    "bam_tumor": tumor,
    "bam_normal": normal,
    "ref": f"s3://{bucket}/inputs/references/GRCh38_no_alt_analysis_set.fna",
    "output_prefix": f"s3://{bucket}/outputs/{name}/",
    "override_basecaller_cfg": model,
}
if tumor2:
    pair["bam_tumor2"] = tumor2
print(json.dumps(pair, indent=2))
PY
if ! err="$(aws stepfunctions start-execution --state-machine-arn "$SM" --name "$NAME" \
              --input "file://runs/${NAME}.json" 2>&1)"; then
  need "the run didn't start. AWS said: ${err}"
fi
echo
echo "STARTED: run ${NAME}"
echo "  Inputs saved in runs/${NAME}.json; results will be in s3://${BUCKET}/outputs/${NAME}/"
echo "  At full coverage, alignment takes about 5 hours and variant calling about 9 more."
echo "Check progress with: bash bin/run-status.sh ${NAME}"
