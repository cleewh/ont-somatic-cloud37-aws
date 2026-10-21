# ONT COLO829 Somatic Pipeline on AWS — cloud37 (B1c)

A transferable, cost-optimized pipeline for running the Oxford Nanopore
`epi2me-labs/wf-somatic-variation` (v1.5.1) somatic workflow on AWS for
tumor-normal pairs (COLO829/COLO829BL and beyond), scaling to 150+ pairs.

The design splits the work into two stages:

1. **Alignment + tumor merge on AWS Batch (on-demand EC2)** — writes aligned BAMs
   directly to S3.
2. **Variant calling on AWS HealthOmics** — a private Nextflow workflow that runs
   on the *pre-aligned* BAMs and is auto-triggered by Step Functions the moment the
   BAMs land in S3.

This is the **B1c** architecture. The two stages are stitched together by a single
Step Functions state machine, so one execution takes raw uBAMs (or aligned BAMs) all
the way to somatic VCFs, methylation, SV calls, and QC.

**Setting this up in your own AWS account? Follow [SETUP.md](SETUP.md)**, a step-by-step
guide that Kiro can run for you with the one-command scripts in `bin/`. The pipeline runs
in **Asia Pacific (Singapore), `ap-southeast-1`**: the scripts use only that region.

---

## Why this architecture (the core optimization)

The obvious approach — run the stock ONT workflow entirely inside HealthOmics — does
not work well here for two reasons discovered during development:

- **HealthOmics tasks are network-isolated.** A task cannot write intermediate data
  to arbitrary S3 during the run, so persisting aligned BAMs for reuse/resume from
  inside the workflow is not possible.
- **In-HealthOmics alignment is expensive and couples align cost to every re-run.**
  Alignment (minimap2 over ~60x ONT genomes) is the single biggest compute block.
  Doing it once on Batch, landing the aligned BAMs in S3, and then running
  *variant-only* on HealthOmics means a re-run of the variant caller (e.g. to tune
  calling) costs ~$12 instead of ~$30, and the aligned BAMs are reusable.

So alignment + merge run on Batch (full control over disk, threads, and S3 output),
and HealthOmics does only the part it is good at: the massively-parallel variant /
methylation / SV calling.

---

## Repository layout

```
SETUP.md                           # step-by-step setup and runs in a new AWS account (with Kiro)
bin/                               # one-command scripts, Singapore (ap-southeast-1) only
  deploy.sh, status.sh             #   set up the pipeline; check setup progress
  upload.sh, start-run.sh          #   upload a pair's BAMs; start a run
  run-status.sh, get-results.sh    #   check a run; download its results
  _common.sh, _*_worker.sh         #   shared code and background parts of the scripts above
.kiro/steering/cloud37-pipeline.md # rules Kiro follows when it operates the pipeline
.gitattributes                     # keeps Unix line endings, so the scripts also run on Windows
production/cloud37/                # the B1c pipeline (this README's subject)
  bootstrap.sh                     # account setup that bin/deploy.sh starts (mirror containers, build, deploy)
  cloud37-build.yaml               # CodeBuild project: mirror ONT containers, build the align image
  cloud37-prereqs.yaml             # run role + run group + HealthOmics workflow/version (IaC)
  cloud37-stack.yaml               # app stack: Step Functions + Batch + manifest Lambda
  Dockerfile                       # align/merge container: minimap2 + samtools + aws-cli
  align_job.sh                     # per-input align job (auto-detects uBAM vs aligned)
  merge_job.sh                     # merges 2 aligned tumor BAMs into 1
production/cloud-pipeline/         # cloud-adapted files of the HealthOmics workflow (overlay on ONT v1.5.1)
  build_workflow_zip.py            # rebuilds the exact workflow ZIP HealthOmics ran (cloud37-variant-rs3)
  main.nf, nextflow.config, nextflow_schema.json, lib/_ingress.nf, modules/…, workflows/…
  LICENSE                          # ONT Public License v1.0 (research use only) for the ONT code
```

---

## Pipeline flow

```
                          ┌─────────────────────── Step Functions ───────────────────────┐
  inputs (uBAM/aligned)   │  Align tumor1 ┐                                                │
  + reference  ──────────▶│  Align tumor2 ┼─(parallel, AWS Batch on-demand EC2)            │
                          │  Align normal ┘                                                │
                          │        │                                                       │
                          │        ▼                                                       │
                          │   Merge tumors (only if 2 tumor files) ─▶ tumor_aligned.bam    │
                          │        │                                                       │
                          │        ▼                                                       │
                          │   omics:StartRun  ─▶ HealthOmics variant-only workflow         │
                          │        │                                                       │
                          │        ▼                                                       │
                          │   Write manifest.json                                          │
                          └────────────────────────────────────────────────────────────────┘
```

- `omics:StartRun` returns immediately (it *starts* the HealthOmics run). The Step
  Functions execution therefore succeeds once the run is triggered and the manifest
  is written; the HealthOmics variant run then completes asynchronously (~8-9 h).

---

## Getting started (new to AWS)

If you have not used AWS before, read this short background, then follow
[SETUP.md](SETUP.md) for the exact commands. You need an AWS account with permission to
create the resources (IAM roles, Batch, HealthOmics, S3, Step Functions,
CloudFormation, CodeBuild).

### How this works (mental model)

You don't "upload the pipeline" to AWS as a bundle. The files in this repo are
**blueprints**. Kiro runs one command (`bash bin/deploy.sh`) from this folder while the
AWS CLI is signed in to your account, and it **creates the pipeline's resources inside
your account** in Singapore (`ap-southeast-1`): it copies the required containers into
your ECR, builds the alignment image in the cloud (CodeBuild), loads the reference genome
into your S3, and deploys the CloudFormation stacks (Batch compute, the Step Functions
pipeline, the HealthOmics workflow, IAM roles). After that
the pipeline **lives in your AWS account** — the downloaded files were just the source.
From then on you just upload BAMs to S3 and start runs.

### Concepts in 60 seconds

- **S3** is where all data lives (inputs, aligned BAMs, results). A **bucket** is a
  top-level container; an **object** is a file identified by its full **key/URI**
  (`s3://my-bucket/inputs/ubam/tumor1.bam`).
- **AWS Batch** runs the alignment/merge on on-demand EC2 virtual machines that scale
  up when there is work and terminate when idle (you pay only while they run).
- **AWS HealthOmics** runs the genomics variant-calling workflow (managed compute).
- **Step Functions** is the conductor that runs the align → merge → trigger sequence.
- **CloudFormation** creates all of the above from the template files in this repo
  (infrastructure as code — reproducible, and deletable in one command).

### Setup and your first run

[SETUP.md](SETUP.md) has the exact steps: the one-time preparation (install the AWS CLI,
`aws login`, and the compute-quota increase new accounts need), the prompt to give Kiro,
and a Kiro prompt for each step of a run. Kiro runs these commands from the repository
folder, one at a time:

| Step | Command |
|------|---------|
| Set up the pipeline (about 30 min, in the background) | `bash bin/deploy.sh`, then `bash bin/status.sh --wait` until it prints `READY` |
| Upload a pair's BAMs (in the background) | `bash bin/upload.sh --sample NAME --tumor FILE [--tumor2 FILE] --normal FILE`, then `bash bin/upload.sh --sample NAME --wait` until `DONE` |
| Start the run | `bash bin/start-run.sh --sample NAME --tumor S3_URI [--tumor2 S3_URI] --normal S3_URI --model MODEL` |
| Check it | `bash bin/run-status.sh RUN_NAME` |
| Download the results (in the background) | `bash bin/get-results.sh RUN_NAME`, then `bash bin/get-results.sh RUN_NAME --wait` until `DONE` |

Every script is safe to run again, and none of them uses a region other than
`ap-southeast-1`. They're tested on Windows (in Git Bash, which SETUP.md has you install)
and macOS; the pipeline they create in AWS is the same either way. Without Kiro, run the
same commands in a terminal with bash, AWS CLI v2 and Python 3, or in AWS CloudShell, a
browser terminal that's already signed in (SETUP.md section 3).

---

## Coming from on-prem? How inputs differ (read this first)

On-prem, `wf-somatic-variation` is pointed at a **folder** — Nextflow reads a local
directory and enumerates the BAMs inside it (via `file()` / `Channel.fromPath` over a
POSIX filesystem). **That does not work on AWS HealthOmics.** HealthOmics stages each
input *parameter* as a single mounted file; it cannot list the contents of an S3
"folder", and neither S3 directory URIs (`s3://…/tumor_bams/`) nor glob URIs
(`s3://…/*.bam`) work — both were tried and both fail at input ingress.

So the cloud pipeline takes **one explicit S3 URI per input file**, not a folder:

| On-prem (folder) | Cloud (this pipeline) |
|------------------|-----------------------|
| point at `…/tumor_bams/` containing 2 tumor BAMs | pass `bam_tumor` = tumor1 URI **and** `bam_tumor2` = tumor2 URI |
| point at `…/normal_bams/` containing 1 normal BAM | pass `bam_normal` = the normal URI |
| Nextflow merges the 2 tumors internally | the Batch **merge** step produces one `tumor_aligned.bam` for HealthOmics |

In short: **list your files explicitly.** If you have two tumor BAMs, give both URIs
(`bam_tumor` + `bam_tumor2`); the pipeline aligns each and merges them for you. There is
no "input folder" parameter.

> S3 is object storage, not a filesystem. `s3://bucket/inputs/ubam/tumor1.bam` is a
> single object (a "key"). A trailing-slash "prefix" like `s3://bucket/inputs/ubam/`
> looks like a folder in the console but is not something the workflow can enumerate.

## Input options

Each run is a Step Functions execution with a JSON payload. `bin/start-run.sh` writes
the payload for you (and keeps a copy in `runs/<run name>.json`); the fields are listed
here for reference. Inputs may be **unaligned BAMs (uBAM)** or **already-aligned BAMs** —
each align job auto-detects which:

- **uBAM** → `samtools reset → fastq → minimap2 (lr:hq) → sort` (recipe byte-for-byte
  matching the HealthOmics `minimap2_alignment` step, so results stay concordant).
- **aligned BAM** → index only, no realignment.

| Field | Required | Meaning |
|-------|----------|---------|
| `sample_name` | yes | Label used in output filenames (e.g. `COLO829`). |
| `bam_tumor` | yes | S3 URI of the (first) tumor BAM. |
| `bam_tumor2` | no | S3 URI of a second tumor BAM. **Omit the key entirely for single-tumor.** |
| `bam_normal` | yes | S3 URI of the normal BAM. |
| `ref` | yes | S3 URI of the reference FASTA (chr-prefixed GRCh38 no-alt; `.fai` sibling expected). |
| `output_prefix` | yes | S3 prefix for this pair's outputs (must end with `/`). |
| `override_basecaller_cfg` | yes | Basecaller model id, e.g. `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`. |

### The four input combinations (all supported)

| Tumor input | 2nd tumor | Behavior |
|-------------|-----------|----------|
| uBAM | `bam_tumor2` set (uBAM) | align both tumors → merge → variant call |
| uBAM | omitted | align single tumor → variant call (no merge) |
| aligned | `bam_tumor2` set (aligned) | index both → merge → variant call |
| aligned | omitted | index single tumor → variant call (no merge) |

Example (two uBAM tumors + uBAM normal):

```json
{
  "sample_name": "COLO829",
  "bam_tumor":  "s3://<bucket>/inputs/ubam/tumor1.ubam.bam",
  "bam_tumor2": "s3://<bucket>/inputs/ubam/tumor2.ubam.bam",
  "bam_normal": "s3://<bucket>/inputs/ubam/normal.ubam.bam",
  "ref":        "s3://<bucket>/inputs/references/GRCh38_no_alt_analysis_set.fna",
  "output_prefix": "s3://<bucket>/outputs/COLO829-<timestamp>/",
  "override_basecaller_cfg": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0"
}
```

> **Basecaller note:** ONT publishes COLO829 SUP basecalls as `...@v4.3.0`, but
> `wf-somatic-variation` v1.5.1's schema enum tops out at `v4.2.0`. Use `v4.2.0`
> (same R10.4.1 SUP family, close ClairS/DSS calibration) — `v4.3.0` is rejected at
> schema validation.

---

## Where the intermediate and output files live

Everything for one pair lives under the single `output_prefix` you pass in:

```
<output_prefix>/
├── aligned_bams/                         # produced by the Batch stage (EC2)
│   ├── tumor1_aligned.bam(.bai)          #   per-tumor aligned BAM (before merge)
│   ├── tumor2_aligned.bam(.bai)          #   present only when bam_tumor2 was supplied
│   ├── tumor_aligned.bam(.bai)           #   the MERGED tumor (what HealthOmics consumes)
│   └── normal_aligned.bam(.bai)          #   aligned normal
├── manifest.json                         # single source of truth for this pair (see below)
└── <healthomics-run-id>/                 # produced by the HealthOmics variant stage
    └── definition/output/<sample_name>/
        ├── snv/vcf/  {sample}_somatic_snv.vcf.gz, _somatic_indel.vcf.gz,
        │             _tumor_germline.vcf.gz, _normal_germline.vcf.gz
        ├── snv/annot/  ClinVar-annotated VCF
        ├── mod/  5mC + 5hmC bedMethyl (tumor + normal), DSS DML/DMR
        ├── sv/   Severus SV output
        ├── qc/   mosdepth / flagstat / read stats
        └── bam/  (haplotagged BAMs, etc.)
```

- **`aligned_bams/`** — the reusable intermediate. For two tumors you get the two
  per-tumor aligned BAMs *and* the merged `tumor_aligned.bam`. To re-run only the
  variant caller (e.g. after tuning), point a HealthOmics run at
  `aligned_bams/tumor_aligned.bam` + `aligned_bams/normal_aligned.bam` — this skips
  the ~5 h alignment entirely (index-only path, ~20 min).
- **`manifest.json`** — locates everything for the pair:

  ```json
  {
    "schema": "cloud37-b1c/1",
    "sample_name": "COLO829",
    "created_utc": "…",
    "source_inputs": { "bam_tumor": "s3://…", "bam_normal": "s3://…" },
    "aligned_bams": { "tumor": "s3://…/aligned_bams/tumor_aligned.bam",
                      "normal": "s3://…/aligned_bams/normal_aligned.bam" },
    "healthomics": { "run_id": "…", "run_output_uri": "s3://…/<run-id>" }
  }
  ```

The merged tumor BAM is written by `merge_job.sh` (`samtools merge -c -p` of the two
coordinate-sorted per-tumor BAMs, then reheader to a single `SM` tag, then index).
Every aligned BAM keeps the read groups (`@RG`: flow cell, platform, basecaller model)
and program history (`@PG`) of its source uBAM, so the merged tumor carries all tumor
read groups, each with `SM` set to `sample_name`.

---

## Optimizations applied (with measured impact)

All figures are for the COLO829 pair (tumor ~96x merged / normal ~59x) in
`ap-southeast-1`, on-demand.

| # | Optimization | Effect |
|---|--------------|--------|
| 1 | **Align on Batch, variant-only on HealthOmics** | Removes in-HealthOmics alignment; makes aligned BAMs reusable so a variant re-run is ~$12 not ~$30. |
| 2 | **c6i.8xlarge, 24 minimap2 threads** (`MAP_THREADS=24, SORT_THREADS=6, BAM2FQ_THREADS=2`) | Align per uBAM **5.2 h → ~3 h** (~43% faster) vs the initial 16-thread build. |
| 3 | **gp3 scratch @ 1000 MiB/s throughput** | The download/upload and `samtools sort` spill/merge are throughput-bound; default 125 MiB/s was the bottleneck. |
| 4 | **gp3 IOPS 16000 → 6000** | Free: align/merge timings identical (workload is throughput- not IOPS-bound). Saves the provisioned-IOPS premium. |
| 5 | **Per-job scratch dir + cleanup-on-exit** (`trap`) | Batch reuses instances; without cleanup, a finished align job's ~500 GB scratch filled the volume and the next job failed at container start. |
| 6 | **`bamstats` c.4xlarge → c.2xlarge** | ~$0.13/run, same runtime (<50% CPU efficiency at c.4xlarge). |
| 7 | **DSS `dss_threads` 1 → 4** | `mod:dss` ran on 1 of 4 cores (~141 min). Uses all 4 on the same instance ($0 extra), roughly halving it; de-risks it as a future long-pole. |
| 8 | **Run cache + run group cap** | Resume skips completed tasks; run group enforces a 72 h wall-clock safety cap. |

### Optimizations we tried and **reverted** (important)

- **pileup_variants / create_paired_tensors memory cuts** — `AnalyzeAHORunPerformance`
  flagged these as over-provisioned and recommended dropping memory (e.g. pileup 12 → 8 GB).
  We tried it and it caused **multi-hour stragglers**: deep pericentromeric regions build
  huge pileup tensors that *thrash* under reduced memory (slow, but no OOM, so no retry
  safety net). One run had 5 pileup shards stuck >270 min vs a <35 min max on 12 GB.
  **Reverted to 12/16 GB (cloud36 known-good).**
  **Lesson:** the perf report's right-size recommendations are *average*-based; for
  ClairS stages whose memory scales with local read depth, do not cut memory below the
  deep-tail requirement.

### Bugs fixed along the way (baked into the templates/scripts)

- **Batch container job role** must trust `ecs-tasks.amazonaws.com` (a dedicated
  `TaskRole`), not the EC2 instance role — otherwise "ECS was unable to assume the role".
- **HealthOmics ECR repository policy** — each mirrored `docker-hub/ontresearch/*` repo
  needs a resource policy granting `omics.amazonaws.com` pull access; the run role's IAM
  permissions alone are not enough. `bootstrap.sh` attaches it to any repo that has no
  policy (it never overwrites an existing one, and stops if that one lacks HealthOmics access).
- **`omics:startRun`** via the Step Functions SDK integration requires a `RequestId`
  idempotency token — injected with `States.UUID()`.
- **Large scratch volume** (1024 GB gp3) — 60x uBAMs are ~130 GB and the merged tumor
  ~292 GB; the default root volume is far too small.
- **uBAM classification** in `align_job.sh` — `samtools view -H | grep -c '^@SQ'` returns
  exit 1 on a uBAM (no `@SQ` lines) and `head -1` triggers SIGPIPE; both must be guarded
  (`|| true` + `set +o pipefail`) or `set -e` aborts the job.
- **Read-group header lost at alignment** — the `samtools fastq | minimap2` stream drops
  the uBAM header, so aligned BAMs had no `@RG` lines (reads kept orphaned `RG:Z` tags)
  and the merge's `SM` rename had nothing to act on. `align_job.sh` now merges the source
  header back in, producing byte-for-byte the header ONT's `reheader_samstream` step
  writes in the HealthOmics alignment. Variant calls were not affected, because the
  workflow takes `sample_name` and `override_basecaller_cfg` as parameters.

---

## Cost & runtime (per tumor-normal pair)

On-demand `ap-southeast-1`: c6i.8xlarge $1.568/hr + 1024 GB gp3 (1000 MiB/s, 6000 IOPS)
= **$1.785/node-hr**.

| Part | Runtime | Cost |
|------|---------|------|
| Align tumor1 (uBAM→BAM) | 2.96 h | $5.28 |
| Align tumor2 | 2.95 h | $5.27 |
| Align normal | 3.69 h | $6.59 |
| Merge tumors (→292 GB) | 2.09 h | $3.74 |
| **Batch front-end (align parallel → merge)** | **~5.0 h wall** | **$20.87** |
| HealthOmics variant call | 8.7 h | $11.58 (task $8.31 + storage $3.27) |
| **Whole pipeline / pair** | **~13.7 h compute (~14.5 h observed)** | **≈ $32.45** |

- Align jobs run in parallel, so the front-end wall-clock is bounded by the normal
  align (~3.7 h) plus the tumor merge (~2.1 h) ≈ 5 h.
- **150 pairs ≈ $4,870** compute. Campaign wall-clock is bounded by Batch + HealthOmics
  concurrency (run group `maxRuns` + Batch scaling), not 150 × 14.5 h.
- Biggest untapped lever: **spot instances** for the ~$20.87 Batch front-end (~70% off,
  ~$15/pair) — not used here by design (on-demand only).

---

## Scaling & concurrency — how many pairs run in parallel

Two kinds of limit decide how many pairs run at once: the pipeline's own caps (stack
parameters, which you can change yourself) and your account's AWS quotas in Singapore
(which you raise in the Service Quotas console).

**The pipeline's caps**

| Limit | Where set | Default | What it caps |
|-------|-----------|---------|--------------|
| Batch `MaxvCpus` | `cloud37-stack.yaml` parameter | **128** | Alignment parallelism. Each align job uses 32 vCPUs and a pair aligns 3 files at once (96 vCPUs), so 128 ≈ **one pair aligning at a time**. |
| Run group `MaxRuns` | `cloud37-prereqs.yaml` parameter | **8** | Pairs in HealthOmics variant calling at once. |
| Run group `MaxDurationMinutes` | `cloud37-prereqs.yaml` parameter | 4320 (72 h) | Per-run wall-clock safety cap. |

**Your account's quotas** (Singapore; the defaults are what a new account gets)

| Quota | Code | New-account default | Needed |
|-------|------|---------------------|--------|
| Amazon EC2: Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances (vCPUs) | `ec2` `L-1216C47A` | **5** | At least **128** before the first run (SETUP.md section 1, step 5); at least `MaxvCpus` after you raise it. |
| AWS HealthOmics: Workflows - Maximum concurrent active runs using dynamic run storage | `omics` `L-BE38079A` | 50 | At least `MaxRuns`. |
| AWS HealthOmics: Workflows - Maximum concurrent tasks per run | `omics` `L-25504C8C` | 25 | Optional. Raising it makes each run faster: the SNV stage has hundreds of short parallel tasks. |
| AWS CodeBuild: Concurrently running builds for Linux/Medium environment | `codebuild` `L-2DC20C30` | 1 (some new accounts are held at 0) | At least 1, for setup only. |

To see your current values:

```bash
aws service-quotas get-service-quota --region ap-southeast-1 --service-code ec2 --quota-code L-1216C47A --query Quota.Value
aws service-quotas get-service-quota --region ap-southeast-1 --service-code omics --quota-code L-BE38079A --query Quota.Value
```

**Out of the box** (after the EC2 increase to 128): about 1 pair aligning at a time and up
to 8 in variant calling. Alignment feeds about 1 pair every 5 hours, so in practice that's
**about 4-5 pairs a day** end to end.

**To scale up**, raise the EC2 quota first, then the caps. For example, for about 10 pairs
aligning at once and up to 50 variant-calling at once, request an EC2 quota of 1,024 and
run, from the repository folder:

```bash
# Alignment: run this when no alignment jobs are running.
aws cloudformation deploy --region ap-southeast-1 --stack-name cloud37 --template-file production/cloud37/cloud37-stack.yaml --capabilities CAPABILITY_IAM --parameter-overrides MaxvCpus=1024

# Variant calling: concurrent HealthOmics runs.
aws cloudformation deploy --region ap-southeast-1 --stack-name cloud37-prereqs --template-file production/cloud37/cloud37-prereqs.yaml --capabilities CAPABILITY_IAM --parameter-overrides MaxRuns=50
```

`cloudformation deploy` keeps every parameter you don't pass at its current value, and
re-running `bash bin/deploy.sh` later keeps these new values too. That range pushes a
150-pair campaign through in a few waves over a few days.

---

## Deploying / transferring to a new AWS account

Everything is parameterized — no account-specific values are baked into the templates.
Setup is two commands, run from the repository folder while the AWS CLI is signed in to
the target account ([SETUP.md](SETUP.md) sections 2-3 have the Kiro prompt and details):

```bash
bash bin/deploy.sh          # prints STARTED within about a minute, or ACTION NEEDED with what to fix
bash bin/status.sh --wait   # repeat until it prints READY (about 30 minutes) or FAILED
```

`bin/deploy.sh` checks the AWS CLI, Python and the sign-in, creates the bucket
`ont-somatic-<account>-ap-southeast-1`, finds the account's default VPC subnets and
security group, and saves them in `setup.env`. It then rebuilds the workflow ZIP, checks it
matches the validated HealthOmics version, and starts `production/cloud37/bootstrap.sh` in
the background. That mirrors the 8 `ontresearch/*` containers into your ECR (with the
repository policy HealthOmics needs to pull them), builds the align image and stages the
reference (all inside **CodeBuild**, so no local Docker is needed), then deploys the
stacks. To use a different bucket or network, put `BUCKET`, `SUBNETS` and
`SECURITY_GROUP` in `setup.env` before running `bin/deploy.sh`; the subnets need internet
access and the security group must allow outbound HTTPS.

Three CloudFormation stacks are created:

| Stack | Contents |
|-------|----------|
| `cloud37-build` | CodeBuild project (privileged, amd64) that mirrors containers + builds the align image. |
| `cloud37-prereqs` | HealthOmics run IAM role, run group (72 h cap), variant-caller workflow + version with container registry map. |
| `cloud37` | Step Functions + AWS Batch (on-demand) + manifest Lambda. |

See `production/cloud37/README.md` for what each file and setup step does.

### Operational notes / gotchas

- **Apply Batch compute-environment changes only when the queue is idle.** A managed CE
  update (instance types, launch template) rolls instances and *kills in-flight jobs*.
- **`cloudformation deploy` reuses previous parameter values** for any parameter not
  passed in `--parameter-overrides` — it does *not* fall back to a changed template
  default. Pass changed params explicitly.

---

## Cost controls & cleanup (important for new users)

Cloud resources cost money while they exist or run. This pipeline is built to avoid
surprises, but know these levers:

- **Compute is on-demand and auto-scaling.** Batch launches EC2 only when a run needs
  it and terminates instances when idle (`MinvCpus: 0`). HealthOmics releases its
  compute on any terminal state. There is **no always-on server** to forget about.
- **The run group is a safety cap.** `cloud37-prereqs` creates a HealthOmics run group
  with a **72 h max duration** and a max concurrent-run limit — a stuck/hung run is
  killed before it can run up unbounded cost.
- **Budget alarm (recommended).** Set an AWS Budgets alert so you're emailed if spend
  exceeds a threshold:
  ```bash
  # Console: Billing → Budgets → Create budget (monthly, e.g. $500, email alert)
  ```
- **Storage is the lingering cost.** Aligned BAMs (~150-300 GB each) and results sit in
  S3 and bill per GB-month until you delete them. Clean up when done:
  ```bash
  aws s3 rm s3://MY-BUCKET/outputs/COLO829-run1/ --recursive   # a pair's outputs
  ```
  Consider an S3 lifecycle rule to auto-expire or archive `outputs/` after N days.
- **Cancel a run** you no longer need:
  ```bash
  aws omics cancel-run --id <run-id> --region ap-southeast-1
  aws stepfunctions stop-execution --execution-arn <arn> --region ap-southeast-1
  ```

### Tear everything down

The infrastructure is three CloudFormation stacks — delete them to remove all
compute/orchestration resources (this does **not** touch your S3 data):

```bash
aws cloudformation delete-stack --stack-name cloud37 --region ap-southeast-1
aws cloudformation delete-stack --stack-name cloud37-build --region ap-southeast-1
aws cloudformation delete-stack --stack-name cloud37-prereqs --region ap-southeast-1
```

Then, if you want the data gone too, empty/delete the S3 bucket and the ECR
repositories (`cloud37-align`, `docker-hub/ontresearch/*`; about 10 GB of container
images, roughly $1 a month). Setup creates these outside the stacks, so deleting the
stacks leaves them in place.

---

## Credential hygiene

All auth is IAM-role based (Batch instance role, ECS task role, Step Functions role,
HealthOmics run role) plus ephemeral ECR tokens. No static credentials are stored in any
artifact or the container image. `.dockerignore` blocks credential files from the build
context. The AWS account ID appears only inside ARNs/config (it is an identifier, not a
secret).

---

## Provenance

Built and validated against ONT `epi2me-labs/wf-somatic-variation` v1.5.1 with the
COLO829/COLO829BL public dataset (`s3://ont-open-data/colo829_2024.03/`). The HealthOmics
workflow is a cloud-adapted fork (`cloud37-variant-rs3`) with an internal 2-tumor merge
path and right-sizing derived from measured per-task performance reports.
`production/cloud-pipeline/` holds only the 8 files that differ from ONT's v1.5.1
release; `build_workflow_zip.py` rebuilds the full 80-file definition from the release
and verifies it is identical to the version registered in HealthOmics.

The ONT code is licensed under the Oxford Nanopore Technologies PLC. Public License v1.0
(`production/cloud-pipeline/LICENSE`), which permits use for research purposes only.
