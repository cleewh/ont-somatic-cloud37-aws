#!/bin/bash
# Launcher: kills any stuck prior merge, fetches the merge script, runs it fully detached.
pkill -9 -f /tmp/merge.sh 2>/dev/null || true
sleep 2
aws s3 cp s3://ont-lrs-somatic-poc-apse1-687677765589/scripts/merge_tumor_bams.sh /tmp/merge.sh --region ap-southeast-1
chmod +x /tmp/merge.sh
setsid bash -c "/tmp/merge.sh > /var/log/merge.log 2>&1" < /dev/null &
disown
sleep 4
echo STARTED
pgrep -af /tmp/merge.sh
tail -5 /var/log/merge.log
