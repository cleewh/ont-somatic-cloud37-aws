# cloud37 (B1c) — align on AWS Batch → HealthOmics variant calling

Alignment and the tumor merge run on on-demand EC2 through **AWS Batch** and write the
aligned BAMs straight to S3. **Step Functions** then starts a **HealthOmics**
variant-calling run on those BAMs. Nothing here is tied to one AWS account: every
account-specific value is a stack parameter that `bootstrap.sh` fills in.

Setting up a new account? Follow [SETUP.md](../../SETUP.md). The normal entry point is
`bash bin/deploy.sh` from the repository folder: it writes `setup.env` and starts
`bootstrap.sh` in the background, and `bash bin/status.sh --wait` reports when it's done.
The `bin/` scripts run everything in Asia Pacific (Singapore), `ap-southeast-1`.

## Files

| File | Role |
|------|------|
| `bootstrap.sh` | Account setup, started by `bin/deploy.sh`; runs everything below. Safe to re-run. |
| `cloud37-build.yaml` | CodeBuild project: mirrors the 8 ONT containers into ECR (with the HealthOmics pull policy) and builds the align image. |
| `cloud37-prereqs.yaml` | HealthOmics run role, run group (72 h cap), variant-caller workflow and version. |
| `cloud37-stack.yaml` | Step Functions, AWS Batch (on-demand), manifest Lambda. |
| `Dockerfile`, `align_job.sh`, `merge_job.sh` | Align/merge container: minimap2 2.28, samtools 1.20, AWS CLI. |

`bootstrap.sh` also writes `deploy.params.json` (not in git), recording the parameters it
passed to the `cloud37` stack.

## What bootstrap.sh does

`bin/deploy.sh` prepares its inputs first: it creates the bucket, finds the default VPC's
subnets and security group, writes them to `setup.env`, and builds
`cloud37-variant-workflow.zip` with `../cloud-pipeline/build_workflow_zip.py` (verified
identical to `cloud37-variant-rs3`). Then it starts:

```bash
bash production/cloud37/bootstrap.sh   # from the repository folder
```

With no arguments, `bootstrap.sh` reads `AWS_REGION`, `BUCKET`, `SUBNETS` and
`SECURITY_GROUP` from `setup.env` in the current folder and uses
`cloud37-variant-workflow.zip`. Optional arguments override them:
`bootstrap.sh [REGION] [BUCKET] [WORKFLOW_ZIP] [REFERENCE_S3_PREFIX]`. It writes its output
to `bootstrap.log` (keeping the previous run's log as `bootstrap.previous.log`) and holds
`bootstrap.lock` while it runs, so only one copy runs at a time.

1. Warns if the EC2 On-Demand vCPU quota is below 96. A pair aligns 3 inputs at once, at
   32 vCPU each.
2. CodeBuild mirrors the 8 pinned `ontresearch/*` images to `docker-hub/ontresearch/*` in
   ECR, attaches the HealthOmics pull policy, and builds `cloud37-align:latest`. No local
   Docker is needed. `BUILD_MODE=local` builds on your machine instead; that needs Docker
   with amd64 support, and you should run `docker logout <ACCT>.dkr.ecr.<REGION>.amazonaws.com`
   afterwards.
3. Stages the GRCh38 no-alt analysis set at `inputs/references/`. By default the same
   CodeBuild run copies GIAB's public copy; with `REFERENCE_S3_PREFIX` it copies your own.
4. Uploads the workflow ZIP and deploys `cloud37-prereqs`.
5. Deploys `cloud37` with the prereqs outputs.

Each step is commented in `bootstrap.sh` if you want to run it by hand.

## Running one tumor-normal pair (per-run input)

`bash bin/start-run.sh` (SETUP.md section 4.2) checks the inputs and starts a Step
Functions execution with this payload, keeping a copy in `runs/<run name>.json`:

```json
{
  "sample_name": "COLO829",
  "bam_tumor":  "s3://<bucket>/inputs/.../tumor1.bam",
  "bam_tumor2": "s3://<bucket>/inputs/.../tumor2.bam",   // OMIT this key entirely for single-tumor
  "bam_normal": "s3://<bucket>/inputs/.../normal.bam",
  "ref":        "s3://<bucket>/inputs/references/GRCh38_no_alt_analysis_set.fna",
  "output_prefix": "s3://<bucket>/outputs/COLO829-<ts>/",
  "override_basecaller_cfg": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0"
}
```

- Inputs may be uBAM or aligned. Each align job detects which: a uBAM goes through
  minimap2, an aligned BAM is only indexed.
- For uBAMs, `align_job.sh` carries the source header (`@RG` read groups, `@PG` history)
  into the aligned BAM, matching the header the HealthOmics alignment step writes.
- Keep inputs under `inputs/` and `output_prefix` under `outputs/`. The HealthOmics run
  role can only read and write those prefixes.

## Output layout (per pair, one prefix)

```
<output_prefix>/
├── aligned_bams/   tumor1_aligned.bam, tumor2_aligned.bam (2 tumors only),
│                   tumor_aligned.bam (what HealthOmics reads), normal_aligned.bam (+ .bai)
├── manifest.json   sources, aligned BAM URIs, HealthOmics run id
└── <healthomics-run-id>/definition/output/   VCFs, methylation, SVs, reports
```

`manifest.json` is the single place to look up a pair's aligned BAMs and variant results.

## Credential hygiene

All auth is IAM-role based (Batch instance and task roles, Step Functions role,
HealthOmics run role) plus short-lived ECR tokens. No static credentials are stored in
any artifact or in the container image; `.dockerignore` keeps credential files out of
the build context.
