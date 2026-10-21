#!/usr/bin/env bash
# The background part of bin/upload.sh: copies a pair's files into the bucket, one by one,
# skipping files that are already there with the same size. Not meant to be run on its own.
#
# Usage: bash bin/_upload_worker.sh PID_FILE BUCKET PREFIX FILE NAME [FILE NAME ...]
source "$(dirname "$0")/_common.sh"
echo $$ > "$1"
bucket="$2" prefix="$3"
shift 3
echo "started $(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
while [[ $# -gt 0 ]]; do
  src="$1" name="$2"
  shift 2
  size="$(python3 -c 'import os, sys; print(os.path.getsize(sys.argv[1]))' "$src")"
  have="$(aws s3api head-object --bucket "$bucket" --key "$prefix/$name" \
            --query ContentLength --output text 2>/dev/null || true)"
  if [[ "$have" == "$size" ]]; then echo "skipped $name (already uploaded)"; continue; fi
  echo "uploading $name from $src ($(( size / 1000000000 )) GB)"
  aws s3 cp --only-show-errors "$src" "s3://$bucket/$prefix/$name" \
    || { echo "ERROR: uploading $src failed"; exit 1; }
  echo "uploaded $name"
done
echo "== upload complete =="
