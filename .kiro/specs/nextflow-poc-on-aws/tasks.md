# Implementation Plan: Nextflow POC on AWS HealthOmics (wf-somatic-variation v1.5.1)

Convert the feature design into a series of prompts for a code-generation LLM that will implement each step with incremental progress. Make sure that each prompt builds on the previous prompts, and ends with wiring things together. There should be no hanging or orphaned code that isn't integrated into a previous step. Focus ONLY on tasks that involve writing, modifying, or testing code.

## Overview

This POC is a one-shot orchestration flow driven by the `aws-healthomics` MCP power and a small number of POSIX shell helpers + JSON config artifacts. The tasks below are ordered by dependency; the DAG scheduler will pick up parallelism where it exists (notably, property tests can run alongside their implementation tasks). All code artifacts land in the operator workstation repo (helpers, JSON templates, tests) or in the POC S3 bucket in `ap-southeast-1` (workflow ZIP, staged inputs, analysis outputs). No general-purpose application code is introduced.

## Task Dependency Graph

The DAG scheduler groups tasks into waves that can execute in parallel. Task numbers refer to top-level tasks; sub-tasks (3.1, 3.2, 4.1, 4.2, 6.1, 6.2) execute within the same wave as their parent.

```json
{
  "waves": [
    {
      "wave": 1,
      "tasks": ["1"],
      "rationale": "Pre-flight + IAM role is the root — nothing runs until account/region/bucket/credentials are verified and the run role exists."
    },
    {
      "wave": 2,
      "tasks": ["2", "3"],
      "rationale": "ECR container mirror setup (Task 2, requires the IAM role to already exist so ECR repository policies can grant HealthOmics access; does NOT depend on Docker Hub credentials in this design) and input staging + compatibility check (Task 3, needs bucket from Task 1) are independent of each other. Within Task 3, sub-task 3.1 (staging + compat check) and 3.2 (Property 1 test) run in parallel within wave 2."
    },
    {
      "wave": 3,
      "tasks": ["4", "5"],
      "rationale": "Pre-merge fallback (Task 4, conditional on Task 3.1 emitting fail: sample_mismatch) and workflow packaging (Task 5, depends on Task 2's PTC for the container registry map coverage assertion) are independent. Within Task 4, sub-task 4.1 (fallback) is the wave-3 leaf (conditional) and 4.2 (Property 2 test) is a parallel optional leaf."
    },
    {
      "wave": 4,
      "tasks": ["6"],
      "rationale": "Task 6 is a composite. Sub-task 6.1 (`CreateAHOWorkflow`) needs the ZIP + parameter template + registry map from Task 5 and the IAM role from Task 1. Sub-task 6.2 (`CreateAHORunGroup`) has no dependencies inside wave 4 — it only needs the IAM role from Task 1 and region access from wave 1. 6.1 and 6.2 execute in parallel within wave 4."
    },
    {
      "wave": 5,
      "tasks": ["7"],
      "rationale": "StartAHORun needs workflow_id from Task 6, staged inputs from Task 3 (or Task 4 if fallback ran), AND `run_group_id` from Task 6.2."
    },
    {
      "wave": 6,
      "tasks": ["8"],
      "rationale": "Post-run analysis + cost extrapolation runs only after Task 7 reaches a terminal status (COMPLETED, FAILED, or CANCELLED)."
    }
  ]
}
```

## Tasks

- [x] 1. Pre-flight verification and IAM role setup
  - Verify AWS caller identity in region `ap-southeast-1` (`aws sts get-caller-identity`, `aws configure get region`).
  - Verify the POC S3 bucket exists in `ap-southeast-1` with `BucketOwnerEnforced`, SSE-S3, versioning enabled, block-public-access on, and a TLS-only bucket policy (`aws s3api get-bucket-location`, `get-bucket-encryption`, `get-bucket-policy`). Create it via `aws s3api create-bucket --create-bucket-configuration LocationConstraint=ap-southeast-1` if missing, then apply the required configuration.
  - **Docker Hub credentials gate** — verify Secrets Manager entry `ecr-pullthroughcache/docker-hub` exists in `ap-southeast-1` with keys `{username, accessToken}` (`aws secretsmanager describe-secret --secret-id ecr-pullthroughcache/docker-hub --region ap-southeast-1`). If missing, prompt the operator for Docker Hub username + access token and create the secret via `aws secretsmanager create-secret`; do not proceed until this succeeds. Record the resulting `credential_arn`.
  - Write `iam/omics-poc-run-role.trust.json` and `iam/omics-poc-run-role.permissions.json` matching the trust policy and permission policy in design § "IAM Role for the HealthOmics Run" verbatim (substituting `<poc-bucket>` and `<account-id>`).
  - Create the role via `aws iam create-role` and attach the permission policy via `aws iam put-role-policy`. Record the role ARN as `omics-poc-run-role-arn` for downstream tasks.
  - _Requirements: 6.2, 10.1, 10.2, 10.4_

- [x] 2. Mirror 8 `ontresearch/*` containers to private ECR (manual pull/push, PTC bypass)
  - **Design deviation note**: The user opted out of authenticated Docker Hub PTC. Instead of `CreatePullThroughCacheForHealthOmics`, this task manually pulls each of the 8 images from Docker Hub, retags to the account's ECR, and pushes. The ECR repository prefix is kept as `docker-hub/*` for compatibility with the IAM policy and container registry map produced in Task 1 and Task 5.
  - For each of the 8 images from design § "Container inventory for wf-somatic-variation v1.5.1" (`wf-somatic-variation:sha5d62edcc2853ce1fd9afc244ff87e65788c4c596`, `wf-somatic-snp:sha86599ecdb46472d01e0b7c2704683f6aee8a82dd`, `clairs-to:sha0bed006dfad374401e9410b44d67e6609f7936e9`, `modkit:shaa7bf2b62946eeb7646b9b9d60b892edfc3b3a52c`, `dss:sha927196d7e068cc49d5a41bcc3db91b9bdf723e7a`, `wf-somatic-sv:sha4b941d684b3310e8524ce169da2d358a6631fab0`, `wf-common:sha72f3517dd994984e0e2da0b97cb3f23f8540be4b`, `snpeff:sha313729d816872d70b410752001a0e2654eb88807`):
    - Create the target ECR repository if missing: `aws ecr create-repository --repository-name docker-hub/ontresearch/<image_name> --region ap-southeast-1 --image-scanning-configuration scanOnPush=true` (idempotent — skip if `RepositoryAlreadyExistsException`).
    - Attach the HealthOmics-access repository policy to the newly-created repo via MCP `GrantHealthOmicsRepository(repository_name="docker-hub/ontresearch/<image_name>", aws_region="ap-southeast-1")`. This grants `omics.amazonaws.com` the required `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` permissions on the repo.
  - Log in to ECR: `aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 687677765589.dkr.ecr.ap-southeast-1.amazonaws.com`.
  - For each of the 8 image + tag pairs:
    - `docker pull ontresearch/<image_name>:<sha_tag>` (anonymous pull from Docker Hub — fits inside Docker Hub's anonymous rate limit of 100 pulls/6h).
    - `docker tag ontresearch/<image_name>:<sha_tag> 687677765589.dkr.ecr.ap-southeast-1.amazonaws.com/docker-hub/ontresearch/<image_name>:<sha_tag>`.
    - `docker push 687677765589.dkr.ecr.ap-southeast-1.amazonaws.com/docker-hub/ontresearch/<image_name>:<sha_tag>`.
  - SMOKE: for each of the 8 images, invoke MCP `CheckContainerAvailability(repository_name="docker-hub/ontresearch/<image_name>", image_tag="<sha_tag>", initiate_pull_through=false, aws_region="ap-southeast-1")`. Assert every response has `available=true` AND `healthomics_accessible=true`. Abort task on any coverage gap (Requirement 5.5).
  - Where to run: the operator's workstation (if Docker is installed and network throughput to Docker Hub + ECR is acceptable) OR a small EC2 instance (`t3.large` with 100 GB EBS gp3) in `ap-southeast-1` if the operator prefers cloud-side push for faster ECR upload. Do NOT create a persistent EC2 — if used, terminate it immediately after the mirror completes to satisfy Requirement 11.1.
  - Record the mirrored image list to `.kiro/specs/nextflow-poc-on-aws/context.json` under `mirrored_containers` as an array of `{repository, tag, digest}` objects (populate `digest` from `docker inspect --format='{{index .RepoDigests 0}}'` after push).
  - _Requirements: 5.3, 5.5, 10.5, 11.1_

- [x] 3. Stage inputs and run compatibility check
  - _Composite task — see sub-tasks 3.1 and 3.2._
  - _Requirements: 2.1, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 10.1, 10.2_

  - [x] 3.1 Stage inputs and execute compatibility check
    - Upload the reference genome to `s3://<poc-bucket>/inputs/references/` — `GRCh38_no_alt_analysis_set.fna`, `.fna.fai`, `.dict`. Locally assert `.fai` exists and non-empty, and that its first column starts with `chr` (design § "Reference Genome Handling"); abort staging on failure.
    - Write `scripts/compatibility_check.sh` implementing the extraction (`samtools view -H` + awk), basecaller resolution (from `@RG DS:`, `@PG PN:dorado CL:`, or `@RG PL:ONT`), and decision function verbatim from design § "Compatibility Check". The script MUST accept three BAM paths (`tumor1`, `tumor2`, `normal`) and the expected basecaller constant `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`, and emit `compatibility-check.json` matching the schema in design § "Data Models". Exit 0 on `pass`, 1 on `fail`.
    - Run `scripts/compatibility_check.sh` against the local tumor1, tumor2, and normal BAMs. Persist output to `analysis/colo829-poc-<UTC_TIMESTAMP>/compatibility-check.json` and upload to `s3://<poc-bucket>/analysis/<run-name>/compatibility-check.json`.
    - If `status="pass"`: upload the two tumor BAMs + `.bai` files to `s3://<poc-bucket>/inputs/tumor_bams/` and the one normal BAM + `.bai` to `s3://<poc-bucket>/inputs/normal_bams/`. Assert exactly 2 objects (+ 2 bai) in `tumor_bams/` and exactly 1 object (+ 1 bai) in `normal_bams/`.
    - If `status="fail"` with `mismatches` containing only `sample_mismatch`: signal Task 4 (pre-merge fallback) to run. Any other failure mode (`basecaller_mismatch`, `basecaller_expected`, `basecaller_unresolved`): abort per design § "Error Handling".
    - _Requirements: 2.1, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 10.1, 10.2_

  - [x] 3.2 Property test — compatibility check decision correctness
    - **Property 1: Compatibility check decision correctness**
    - Generate random synthetic BAM header trios (2 tumor + 1 normal): vary `SM` tag values (singleton vs multi-value across the two tumor headers), basecaller tokens (matching the expected constant vs varied), and encoding location (`@RG DS:`, `@PG dorado CL:`, `@RG PL:ONT`). Include the `basecaller_unresolved` edge case (no parseable token).
    - Invoke `scripts/compatibility_check.sh` (or an extracted decision function) against each generated trio.
    - Assert: `status="pass"` **if and only if** the union of `SM` values across both tumor headers is a singleton set AND all three basecaller identifiers equal `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`.
    - Assert: whenever `status="fail"`, `mismatches` is non-empty and every named tag corresponds to a demonstrable inequality in the generated input (e.g., `sample_mismatch` only appears when the SM union is not a singleton).
    - Minimum 100 iterations. Test tag: `Feature: nextflow-poc-on-aws, Property 1: Compatibility check decision correctness`.
    - **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

- [x] 4. Pre-merge fallback (conditional — only if Task 3.1 emitted `fail: sample_mismatch`)
  - _Composite task — see sub-tasks 4.1 and 4.2._
  - _Not triggered — Task 3.1 compat check passed (status=pass); no fallback needed._
  - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [x] 4.1 Execute pre-merge fallback (conditional) — SKIPPED (not triggered — compat check passed)
    - Write `scripts/pre_merge_fallback.sh` implementing the merge + reheader flow verbatim from design § "Pre-Merge Fallback (conditional)": `samtools merge -c -p` → `samtools view -H | sed …SM:…` → `samtools reheader` → `samtools index`. The script MUST accept the two tumor BAM paths and a target `SM` value, and produce a single reheadered BAM + `.bai`.
    - Execute the script against the local tumor BAMs with target `SM=COLO829`. Upload the single merged BAM + `.bai` to `s3://<poc-bucket>/inputs/tumor_bams/` (which MUST now contain exactly one BAM object + its `.bai`, per Requirement 4.3). Also upload the normal BAM + `.bai` to `s3://<poc-bucket>/inputs/normal_bams/`.
    - Re-run `scripts/compatibility_check.sh` against the merged tumor BAM (twice, since the check expects two tumor inputs — pass the same file both times, or extract the decision function to accept a single tumor BAM in fallback mode) and the normal BAM. Assert the new result is `status="pass"`; abort if not.
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [ ]* 4.2 Property test — pre-merge fallback unifies the sample tag (optional)
    - **Property 2: Pre-merge fallback unifies the sample tag**
    - Generate random synthetic BAM pairs whose combined `@RG` `SM` tag values form a non-singleton set (2–5 distinct values across the two headers), plus a random target `SM` string.
    - Execute `scripts/pre_merge_fallback.sh` against each generated pair.
    - Assert: the output BAM's `@RG` `SM` values form the singleton set `{target_sm}`.
    - Assert: the output BAM's alignment record count equals the sum of the two input BAMs' alignment record counts (no records dropped or duplicated by merge + reheader).
    - Minimum 100 iterations. Test tag: `Feature: nextflow-poc-on-aws, Property 2: Pre-merge fallback unifies the sample tag`.
    - **Validates: Requirements 4.2**

- [x] 5. Package the v1.5.1 workflow definition (fetch, version-pin, template + registry map, S3 ZIP)
  - Fetch `https://github.com/epi2me-labs/wf-somatic-variation/archive/refs/tags/v1.5.1.tar.gz` to a local scratch directory. The URL string MUST literally contain `refs/tags/v1.5.1` — any other Git reference aborts (Requirement 1.4).
  - Extract; assert the root is `wf-somatic-variation-1.5.1/`. Verify version pin via `grep -q "version *= *'v1.5.1'" wf-somatic-variation-1.5.1/nextflow.config` (EXAMPLE test for Requirement 1.4 — abort with `version_mismatch` on failure).
  - Write `workflow-artifacts/parameter-template.json` matching design § "Parameter template" verbatim (required keys `sample_name`, `ref`, `bam_tumor`, `bam_normal`, `override_basecaller_cfg`; optional keys with `"optional": true`). Cross-check every schema-required key from `wf-somatic-variation-1.5.1/nextflow_schema.json` is present; abort on any missing key.
  - Write `workflow-artifacts/container-registry-map.json` with the single `registryMappings` entry from design § "Container registry map (registryMappings only)" (`registry-1.docker.io` → `docker-hub`). Alternatively, generate it via MCP `CreateContainerRegistryMap(include_pull_through_caches=true, ecr_region="ap-southeast-1", ecr_account_id=<account>)` and assert the returned map contains exactly the expected entry.
  - MCP: `PackageAHOWorkflow(main_file_content=".../wf-somatic-variation-1.5.1/main.nf", main_file_name="main.nf", additional_files={"nextflow.config": ".../nextflow.config", "nextflow_schema.json": ".../nextflow_schema.json", "lib/": ".../lib/", "subworkflows/": ".../subworkflows/", "modules/": ".../modules/", "bin/": ".../bin/"}, output_path="s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip")`.
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 5.6_

- [x] 6. Create the AHO_Workflow and the Run_Group safety cap
  - _Composite task — see sub-tasks 6.1 and 6.2._
  - _Requirements: 1.1, 5.1, 5.2, 5.4, 5.6, 10.3, 11.1, 11.2, 11.4_

  - [x] 6.1 Create the AHO_Workflow via `CreateAHOWorkflow`
    - Best-effort preflight: MCP `LintAHOWorkflowBundle(workflow_files="s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip", workflow_format="nextflow", main_workflow_file="main.nf")`. If the tool returns `unsupported format` for Nextflow, skip lint (design § "Packaging steps (Option B)" step 5); do not block workflow creation.
    - MCP: `CreateAHOWorkflow(name="wf-somatic-variation-v1_5_1", engine="NEXTFLOW", definition_uri="s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip", parameter_template=<from parameter-template.json>, container_registry_map=<from container-registry-map.json>, aws_region="ap-southeast-1", tags={"pipeline_version":"v1.5.1","poc":"colo829"})`.
    - SMOKE: `GetAHOWorkflow(workflow_id=<returned>, aws_region="ap-southeast-1")` and assert `engine="NEXTFLOW"`, region is `ap-southeast-1`, the container registry map has exactly one `registryMappings` entry with `upstreamRegistryUrl="registry-1.docker.io"` and `ecrRepositoryPrefix="docker-hub"`, and the parameter template contains every required key from Task 5.
    - Record `workflow_id` for Task 7.
    - _Requirements: 1.1, 5.1, 5.2, 5.4, 5.6, 10.3_

  - [x] 6.2 Create or reuse the Run_Group safety cap
    - MCP: `ListAHORunGroups(name="omics-poc-run-group-72h", aws_region="ap-southeast-1")` — check for an existing group.
    - If a group with the exact name exists AND `maxDuration=4320` AND `maxRuns=1`: reuse it. Record its `id` as `run_group_id`.
    - If a group with the exact name exists but with different config: MCP `UpdateAHORunGroup(run_group_id=<existing>, max_duration=4320, max_runs=1, aws_region="ap-southeast-1")`. Assert the update returned success. Record the id.
    - If no matching group exists: MCP `CreateAHORunGroup(name="omics-poc-run-group-72h", max_duration=4320, max_runs=1, tags={"pipeline_version":"v1.5.1","poc":"colo829"}, aws_region="ap-southeast-1")`. Record the returned `id` as `run_group_id`.
    - SMOKE: MCP `GetAHORunGroup(run_group_id=<recorded>, aws_region="ap-southeast-1")` and assert `maxDuration==4320`, `maxRuns==1`, region is `ap-southeast-1`.
    - Persist `run_group_id` to `analysis/colo829-poc-<UTC_TIMESTAMP>/run-group.json` with `{"id": "<id>", "name": "omics-poc-run-group-72h", "max_duration_minutes": 4320, "max_runs": 1, "region": "ap-southeast-1"}` for downstream reference.
    - _Requirements: 11.1, 11.2, 11.4_

- [x] 7. Start the POC run via `StartAHORun` and poll to terminal status
  - Run submitted: id=3527486, name=colo829-poc-20260702T230200Z, status=STARTING at submit time. Poll deferred to `scripts/watch_run.sh 3527486` — do not busy-wait in this sub-agent invocation.
  - Generate `<UTC_TIMESTAMP>` in `YYYYMMDDTHHMMSSZ` format; set `run_name = "colo829-poc-<UTC_TIMESTAMP>"`.
  - **Pre-flight assertion (Requirement 11.5):** verify that `run_group_id` recorded by Task 6.2 is non-null and non-empty. If it is missing, abort with `run_group_id_missing` **before** invoking `StartAHORun` — do not submit the run.
  - MCP: `StartAHORun(workflow_id=<from Task 6>, role_arn=<from Task 1>, run_group_id=<from Task 6.2>, name=<run_name>, output_uri="s3://<poc-bucket>/outputs/<run_name>/", storage_type="DYNAMIC", aws_region="ap-southeast-1", parameters={"sample_name":"COLO829","ref":"s3://<poc-bucket>/inputs/references/GRCh38_no_alt_analysis_set.fna","bam_tumor":"s3://<poc-bucket>/inputs/tumor_bams/","bam_normal":"s3://<poc-bucket>/inputs/normal_bams/","snv":true,"sv":true,"mod":true,"diff_mod":true,"annotation":true,"override_basecaller_cfg":"dna_r10.4.1_e8.2_400bps_sup@v4.2.0","ubam_map_threads":8,"ubam_sort_threads":3,"ubam_bam2fq_threads":1,"severus_threads":8,"haplotype_filter_threads":4,"modkit_threads":4,"dss_threads":1})`. Match the design's authoritative call signature in § "Run Submission → `StartAHORun` call" verbatim. Assert `run_group_id` in the submitted call equals the ID recorded by Task 6.2 (Requirement 11.2). Assert `bam_tumor` and `bam_normal` end with `/` (they are S3 prefixes, not object keys — Requirements 2.2, 2.5) and that no `samtools merge` step ran on AWS between staging and `StartAHORun` (Requirement 2.3).
  - Poll MCP `GetAHORun(run_id=<returned>, aws_region="ap-southeast-1")` every 60 seconds until status is terminal (`COMPLETED`, `FAILED`, or `CANCELLED`). Record the terminal status and stop time. SMOKE: verify the terminal-state timestamp is present and confirm no orphaned EC2 instances, Batch compute environments, or Auto Scaling groups tagged for the POC exist in `ap-southeast-1` after the terminal transition (Requirement 11.1).
  - INTEGRATION: on `COMPLETED`, list `s3://<poc-bucket>/outputs/<run_name>/` and assert non-empty prefixes for `snv/`, `sv/`, `mod/`, `annotation/`, `qc/`, and `execution/` (Requirement 6.4).
  - _Requirements: 2.2, 2.3, 2.5, 6.1, 6.2, 6.3, 6.4, 10.4, 11.1, 11.2, 11.3, 11.5_

- [x] 8. Post-run analysis and cost extrapolation
  - DONE. Analyzed run 3295679 (colo829-poc-20260704T0552Z-tuned2, v1_5_1-tuned2) which reached terminal CANCELLED (operator-initiated, wall-clock ~8.50h). Ran AnalyzeAHORunPerformance (headroom=0.20, detailed=true) + GenerateAHORunTimeline; skipped DiagnoseAHORunFailure (cancelled, root cause = known evaluate_candidates straggler). Observed per-run $5.4552 (task $3.7676 + storage $1.6876), savings $0.3061. CPU verdict: pileup_variants NOT CPU-bound (~1 core used at 4 CPU) and evaluate_candidates needs finer sharding not more cores. Cost to 150 pairs: as-run $818.28, optimized $772.37. Artifacts (performance-report.json/.md, timeline.svg, cost-extrapolation.json/.md, findings.md) written locally to analysis/colo829-poc-20260704T0552Z-tuned2/ and to s3://ont-lrs-somatic-poc-apse1-687677765589/analysis/colo829-poc-20260704T0552Z-tuned2/. context.json updated with final numbers + terminal status.
  - On `COMPLETED` **or** `FAILED`: MCP `AnalyzeAHORunPerformance(run_ids=[<run_id>], headroom=0.20, detailed=false, aws_region="ap-southeast-1")`. Persist the returned report to `s3://<poc-bucket>/analysis/<run_name>/performance-report.json`. If any per-task recommendation is inconclusive, re-invoke with `detailed=true` and persist alongside as `performance-report.detailed.json`. SMOKE: assert the report contains per-task CPU utilization, memory utilization, cost figures, and a right-sizing recommendation per task (Requirements 7.2, 8.1, 8.2).
  - On `COMPLETED` **or** `FAILED`: MCP `GenerateAHORunTimeline(run_id=<run_id>, time_unit="hr", region="ap-southeast-1", output_format="svg", output_path="s3://<poc-bucket>/analysis/<run_name>/timeline.svg", theme="light", aws_region="ap-southeast-1")`. Assert the SVG object exists in the POC bucket (Requirement 7.4).
  - On `FAILED` only: MCP `DiagnoseAHORunFailure(run_id=<run_id>, detailed=false, aws_region="ap-southeast-1")`. Persist to `s3://<poc-bucket>/analysis/<run_name>/failure-diagnosis.json`. If `recommendations` is non-specific or `failureReason` is generic, re-invoke with `detailed=true` and persist as `failure-diagnosis.detailed.json` (Requirement 6.5).
  - On `CANCELLED`: inspect the cancellation reason from `GetAHORun`. If the reason indicates the Run_Group `maxDuration` cap was hit (Requirement 11.3), **still** run `AnalyzeAHORunPerformance` and `GenerateAHORunTimeline` (partial task metrics identify the hung task that consumed the runway) — persist to the same `analysis/<run_name>/` locations as above. **Skip** `DiagnoseAHORunFailure` because the root cause is already known (duration cap). Reference design § "On CANCELLED" for handling rationale.
  - Compute the cost extrapolation and write both `analysis/<run_name>/cost-extrapolation.json` (schema: `{region, storage_type, pipeline_version, headroom, pair_count, per_run_cost_observed_usd, total_cost_observed_usd, per_run_cost_rightsized_usd, total_cost_rightsized_usd, notes}` from design § "Data Models") and `cost-extrapolation.md` (human-readable). EXAMPLE test: assert `total_cost_observed_usd == per_run_cost_observed_usd * 150` and `total_cost_rightsized_usd == per_run_cost_rightsized_usd * 150` (Requirements 9.1, 9.3). Persist `region="ap-southeast-1"`, `storage_type="DYNAMIC"`, `pipeline_version="v1.5.1"`, `pair_count=150`, `headroom=0.20` (Requirement 9.2).
  - _Requirements: 6.5, 7.1, 7.2, 7.3, 7.4, 8.1, 8.2, 9.1, 9.2, 9.3, 11.3_

## Notes

- Sub-tasks postfixed with `*` (only **4.2** — Property 2) are optional and can be skipped for a fast MVP; Property 1 (sub-task 3.2) is mandatory per design § "Testing Strategy".
- SMOKE / INTEGRATION / EXAMPLE tests are folded into their parent implementation tasks as inline assertions — no stand-alone test-only tasks are created.
- Task 4 is conditional: only runs when Task 3.1's compatibility check fails with `sample_mismatch`. For the COLO829 POC inputs, Task 3.1 is expected to pass and Task 4 will be skipped.
- Every MCP tool invocation is issued through the `aws-healthomics` power with `aws_region="ap-southeast-1"` — the region constraint (Requirement 10.x) and the Run_Group region binding (Requirement 11.2) are enforced tool-call-by-tool-call, not as separate tasks.
- Task 2 uses a manual docker pull/push mirror (no Docker Hub PTC). Anonymous pulls from Docker Hub are used; the 8 images fit inside Docker Hub's anonymous rate limit. See design § "Container Registry Strategy" — the container registry map in Task 5 still resolves `registry-1.docker.io` → `docker-hub` prefix, so no downstream changes are needed.
- Task 5's version-pin assertion (`grep "version *= *'v1.5.1'" nextflow.config`) covers the version-mismatch abort of Requirement 1.4.
- Task 6.2 creates or reuses the run group `omics-poc-run-group-72h` with `maxDuration=4320` minutes (72 h) and `maxRuns=1` — this is the hard wall-clock cap that guarantees Requirement 11 (a stuck or hung run is terminated by HealthOmics before compute cost runs unbounded). Task 7's `StartAHORun` call MUST include this `run_group_id`; a run without it is not eligible for Requirement 11 compliance, and Task 7's pre-flight assertion enforces this (Requirement 11.5).
- Task 6.2 is idempotent — if a run group named `omics-poc-run-group-72h` already exists in `ap-southeast-1` with matching config (`maxDuration=4320`, `maxRuns=1`), it is reused rather than recreated. This keeps the POC re-runnable without accumulating run groups.
- HealthOmics auto-releases compute on any terminal state (`COMPLETED`, `FAILED`, `CANCELLED`) — the POC design creates no long-lived EC2, Batch, ECS, or ASG resources, so no explicit teardown task is needed. See design § "Run Group (safety cap)" → "HealthOmics-native compute lifecycle (context)".
- Manual cancellation is available at any time via `aws omics cancel-run --id <run-id> --region ap-southeast-1` (see design § "Run Group (safety cap)" → "Cost-safety guarantee matrix" for context; not automated in the task list).
