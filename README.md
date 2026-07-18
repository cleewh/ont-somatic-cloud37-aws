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
production/cloud37/                # the B1c pipeline (this README's subject)
  cloud37-stack.yaml               # app stack: Step Functions + Batch + manifest Lambda
  cloud37-prereqs.yaml             # run role + run group + HealthOmics workflow/version (IaC)
  cloud37-build.yaml               # CodeBuild project to build the align image (no local Docker)
  bootstrap.sh                     # one-command account setup (mirror containers, build, deploy)
  Dockerfile                       # align/merge container: minimap2 + samtools + aws-cli
  align_job.sh                     # per-input align job (auto-detects uBAM vs aligned)
  merge_job.sh                     # merges 2 aligned tumor BAMs into 1
  write_manifest.py                # manifest Lambda reference
  deploy.params.json              # the only file a new account edits
production/cloud-pipeline/         # the HealthOmics Nextflow workflow (cloud36 unified + rs tuning)
  main.nf, nextflow.config, nextflow_schema.json, lib/_ingress.nf, modules/…
iam/                               # HealthOmics run role policy documents
scripts/                          # analysis / diagnostics one-offs used during development
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
- **`omics:startRun`** via the Step Functions SDK integration requires a `RequestId`
  idempotency token — injected with `States.UUID()`.
- **Large scratch volume** (1024 GB gp3) — 60x uBAMs are ~130 GB and the merged tumor
  ~292 GB; the default root volume is far too small.
- **uBAM classification** in `align_job.sh` — `samtools view -H | grep -c '^@SQ'` returns
  exit 1 on a uBAM (no `@SQ` lines) and `head -1` triggers SIGPIPE; both must be guarded
  (`|| true` + `set +o pipefail`) or `set -e` aborts the job.

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

## Deploying / transferring to a new AWS account

Everything is parameterized — no account-specific values are baked into the templates.
The one-command path (`bootstrap.sh`) mirrors the 8 `ontresearch/*` containers to your
ECR, builds the align image (via **CodeBuild**, so no local Docker and any host
architecture works), stages the reference, deploys the prereqs + app stacks, and wires
`deploy.params.json`:

```bash
export SUBNETS=subnet-aaa,subnet-bbb,subnet-ccc      # your VPC subnets for Batch
export SECURITY_GROUP=sg-xxxx                         # your Batch security group
./production/cloud37/bootstrap.sh <REGION> <BUCKET> <WORKFLOW_ZIP>
```

Three CloudFormation stacks are created:

| Stack | Contents |
|-------|----------|
| `cloud37-build` | CodeBuild project (privileged, amd64) that mirrors containers + builds the align image. |
| `cloud37-prereqs` | HealthOmics run IAM role, run group (72 h cap), variant-caller workflow + version with container registry map. |
| `cloud37` | Step Functions + AWS Batch (on-demand) + manifest Lambda. |

See `production/cloud37/README.md` for the step-by-step / manual path.

### Operational notes / gotchas

- **Apply Batch compute-environment changes only when the queue is idle.** A managed CE
  update (instance types, launch template) rolls instances and *kills in-flight jobs*.
- **`cloudformation deploy` reuses previous parameter values** for any parameter not
  passed in `--parameter-overrides` — it does *not* fall back to a changed template
  default. Pass changed params explicitly.

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
