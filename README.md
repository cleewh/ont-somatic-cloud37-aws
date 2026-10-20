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
guide that Kiro can run for you.

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
SETUP.md                           # step-by-step setup + first run in a new AWS account
production/cloud37/                # the B1c pipeline (this README's subject)
  bootstrap.sh                     # one-command account setup (mirror containers, build, deploy)
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
**blueprints**. You run one command (`bootstrap.sh`) from a terminal that's logged into
AWS, and it **creates the pipeline's resources inside your account**: it copies the
required containers into your ECR, builds the alignment image in the cloud (CodeBuild),
loads the reference genome into your S3, and deploys the CloudFormation stacks (Batch
compute, the Step Functions pipeline, the HealthOmics workflow, IAM roles). After that
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

[SETUP.md](SETUP.md) walks through the whole thing with copy-paste commands: the
compute-quota check new accounts need, bucket and network, building the workflow
package, `bootstrap.sh`, uploading BAMs, starting a pair, watching it, and finding the
results. Kiro can run it for you. Run it in AWS CloudShell (a browser terminal that is
already signed in) or anywhere with bash and AWS CLI v2.

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

Start a Step Functions execution with a JSON payload. Inputs may be **unaligned
BAMs (uBAM)** or **already-aligned BAMs** — each align job auto-detects which:

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

The account-level AWS quotas are generous; the practical limits are two **self-imposed
config caps** you can raise without any AWS support request (up to the account quotas).

| Limit | Where set | Default | What it caps |
|-------|-----------|---------|--------------|
| Batch `MaxvCpus` | `cloud37-stack.yaml` param | **128** | Alignment parallelism. Each align job = 32 vCPU; a pair runs 3 in parallel (96 vCPU), so 128 ≈ **one pair aligning at a time**. |
| Run group `MaxRuns` | `cloud37-prereqs.yaml` param | **8** | How many pairs are in HealthOmics variant calling at once. |
| Run group `MaxDuration` | `cloud37-prereqs.yaml` param | 4320 (72 h) | Per-run wall-clock safety cap. |

**Out of the box:** ~1 pair aligning at a time, up to 8 in variant calling — but since
alignment feeds only ~1 pair per ~4-5 h, in practice ~1 aligning + ~1-2 calling at any
moment → **~4-5 pairs/day** end-to-end.

**To scale up (no AWS quota request needed — the account already allows it):**

- Raise Batch `MaxvCpus` (e.g. `128 → 1024`) → ~10 pairs aligning in parallel. The
  account's EC2 On-Demand vCPU quota is already ~1,152.
- Raise run group `MaxRuns` (`8 → up to 50`) → up to ~50 pairs variant-calling at once.
  The account's "concurrent active runs (DYNAMIC storage)" quota is 50.

  ```bash
  # Alignment compute (redeploy the app stack when the Batch queue is idle):
  aws cloudformation deploy --template-file production/cloud37/cloud37-stack.yaml \
    --stack-name cloud37 --capabilities CAPABILITY_IAM --region <REGION> \
    --parameter-overrides <existing params…> MaxvCpus=1024

  # Concurrent variant runs (run group):
  aws omics update-run-group --id <run-group-id> --max-runs 50 --region <REGION>
  ```

That range comfortably pushes the full 150-pair campaign through in a few waves over a
few days.

**When you actually need an AWS service-limit (quota) increase** — only beyond the
account quotas above:

| Quota | Default (this account) | Raise if… |
|-------|------------------------|-----------|
| EC2 On-Demand Standard vCPUs (`ec2` / `L-1216C47A`) | ~1,152 | you want >~12 pairs aligning at once |
| HealthOmics concurrent active runs (DYNAMIC storage) | 50 | you want >50 pairs variant-calling at once |
| HealthOmics **tasks per run** | 25 | you want each *individual* run faster (the SNV stage has hundreds of short parallel tasks; raising this is the biggest single-run speedup lever) |

Request these in the **Service Quotas** console (or via AWS support); increases are
usually granted quickly.

---

## Deploying / transferring to a new AWS account

Everything is parameterized — no account-specific values are baked into the templates.
The one-command path (`bootstrap.sh`) mirrors the 8 `ontresearch/*` containers to your
ECR (with the repository policy HealthOmics needs to pull them), builds the align image
(via **CodeBuild**, so no local Docker and any host architecture works), stages the
reference, and deploys the prereqs + app stacks ([SETUP.md](SETUP.md) has the full
sequence, including how to find the subnets and security group):

```bash
python3 production/cloud-pipeline/build_workflow_zip.py   # -> cloud37-variant-workflow.zip
export SUBNETS=subnet-aaa,subnet-bbb,subnet-ccc      # your VPC subnets for Batch
export SECURITY_GROUP=sg-xxxx                         # your Batch security group
bash production/cloud37/bootstrap.sh <REGION> <BUCKET> cloud37-variant-workflow.zip
```

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
repositories (`cloud37-align`, `docker-hub/ontresearch/*`).

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
