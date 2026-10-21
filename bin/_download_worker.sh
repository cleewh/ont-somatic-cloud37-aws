#!/usr/bin/env bash
# The background part of bin/get-results.sh: downloads a run's results, leaving the BAM and
# CRAM files in S3. Not meant to be run on its own.
#
# Usage: bash bin/_download_worker.sh PID_FILE S3_SOURCE LOCAL_FOLDER
source "$(dirname "$0")/_common.sh"
echo $$ > "$1"
aws s3 sync --only-show-errors "$2" "$3" \
  --exclude "*.bam" --exclude "*.bam.bai" --exclude "*.cram" --exclude "*.crai"
echo "== download complete =="
