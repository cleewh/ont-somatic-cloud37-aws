---
inclusion: always
---
# Operating the cloud37 pipeline

This repository sets up and runs the cloud37 ONT somatic pipeline (AWS Batch + AWS
HealthOmics) in the user's own AWS account. SETUP.md is the guide. The person asking may be
new to AWS and to Kiro, so explain results in plain language.

When you're asked to set up the pipeline, upload data, start or check a run, or download
results:

- Use the scripts in `bin/` from the repository folder, exactly as SETUP.md describes, one
  command at a time: `bash bin/deploy.sh`, `bash bin/status.sh --wait`,
  `bash bin/upload.sh ...`, `bash bin/start-run.sh ...`, `bash bin/run-status.sh ...`,
  `bash bin/get-results.sh ...`.
- Setup, uploads and downloads run in the background. Start them once, then check on them
  with the matching status command; never start a second copy while one is running. Don't
  run `production/cloud37/bootstrap.sh` directly.
- Everything runs in Asia Pacific (Singapore), ap-southeast-1. Don't use, suggest or create
  resources in any other region.
- Don't edit repository files or change pipeline settings (instance types, vCPUs, memory,
  threads, disk sizes, workflow files).
- When a script prints ACTION NEEDED or FAILED, show its message and the matching row of
  SETUP.md section 5. Don't work around it, and don't delete or change AWS resources unless
  the user asks.

These rules are for operating the pipeline. They don't apply when the user asks you to work
on the pipeline's code.
