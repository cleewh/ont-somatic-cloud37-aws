# Production runbook — 150 tumor/normal pairs on AWS HealthOmics

Cloud-adapted, HealthOmics-only. One run per pair does **merge + variant calling**
(no EC2, no separate merge step). Region: `ap-southeast-1`. Account: `687677765589`.

## The cloud pipeline

`wf-somatic-variation` was forked into a **cloud-adapted version** (source in
`production/cloud-pipeline/`, registered as workflow version **`v1_5_1-cloud`**
on workflow `2590600`). Changes vs the customer's on-prem pipeline:

1. **Internal tumor merge.** Added an optional `bam_tumor2` parameter and a
   `merge_tumor` process. When two tumor BAMs are supplied, the pipeline merges
   them into one sorted, re-headered BAM internally (via the `wf_common`
   samtools container) and feeds it to the existing `ingress_tumor` path. When
   `bam_tumor2` is unset it behaves **exactly** as on-prem (no regression).
   This removes the need for the earlier EC2 pre-merge entirely.
2. **Right-sizing** (from the POC perf report, baked into `nextflow.config`):
   `clairs_extract_candidates`/`pileup_variants` → 2 CPU (c.large-class),
   `evaluate_candidates` kept at 4 CPU, `merge_tumor` at 8 CPU/16 GiB.
3. Pipeline logic otherwise unchanged; still pinned to upstream **v1.5.1**.

> The two 30x tumor BAMs no longer need a directory or a pre-merge — pass them
> as `bam_tumor` + `bam_tumor2` and the pipeline handles the rest in one run.

## One-time setup (already created during the POC — reuse)

| Resource | ID / value |
|---|---|
| S3 bucket | `ont-lrs-somatic-poc-apse1-687677765589` |
| IAM run role | `omics-poc-run-role` |
| ECR mirror (8 `ontresearch/*` images) | `docker-hub/ontresearch/*`, HealthOmics-accessible |
| Cloud workflow version | `v1_5_1-cloud` (workflow `2590600`) |
| Run cache | `6598859` (`CACHE_ALWAYS`) |

### Create a production run group (once)

```
CreateAHORunGroup(
  name="omics-prod-150pairs",
  max_duration=4320,     # 72h per-run safety cap
  max_runs=<N>,          # concurrency (quota/budget bound); parallelism is the
                         # real throughput lever and isolates any straggler pair
  aws_region="ap-southeast-1")
```

## Per-pair execution — ONE run, no EC2

```
StartAHORun(
  workflow_id=2590600,
  workflow_version_name="v1_5_1-cloud",
  role_arn="arn:aws:iam::687677765589:role/omics-poc-run-role",
  run_group_id=<omics-prod-150pairs>,
  cache_id="6598859", cache_behavior="CACHE_ALWAYS",
  storage_type="DYNAMIC",
  name="<SAMPLE>",
  output_uri="s3://.../outputs/<SAMPLE>/",
  aws_region="ap-southeast-1",
  parameters={
    "sample_name": "<SAMPLE>",
    "ref": "s3://.../references/GRCh38_no_alt_analysis_set.fna",
    "bam_tumor":  "s3://.../<SAMPLE>/tumor1.bam",   # tumor BAM 1
    "bam_tumor2": "s3://.../<SAMPLE>/tumor2.bam",   # tumor BAM 2 (cloud-only) -> merged internally
    "bam_normal": "s3://.../<SAMPLE>/normal.bam",   # single normal BAM
    "snv": true, "sv": true, "mod": true, "diff_mod": true, "annotation": true,
    "override_basecaller_cfg": "<SEE NOTE 1>",
    "ubam_map_threads": 16, "severus_threads": 16, "modkit_threads": 8,
    "ubam_sort_threads": 6, "haplotype_filter_threads": 8,
    "ubam_bam2fq_threads": 2, "dss_threads": 2
  })
```

Drive all 150 via **`StartAHORunBatch`** with `inlineSettings` (one entry per
sample overriding `sample_name`/`bam_tumor`/`bam_tumor2`/`bam_normal`/`output_uri`)
against the run group — HealthOmics schedules up to `max_runs` concurrently.

## ⚠️ Validate before the 150-pair campaign

The cloud-pipeline `main.nf` merge injection was **not executable-tested locally**
(no Nextflow/data on the workstation). Do **one validation run** first — the raw
COLO829 tumor BAMs are still staged, so:

```
bam_tumor  = s3://.../inputs/tumor_bams/PAU59949.d052sup4305mCG_5hmCGvHg38.bam
bam_tumor2 = s3://.../inputs/tumor_bams/PAU61426.d052sup4305mCG_5hmCGvHg38.bam
bam_normal = s3://.../inputs/normal_single/normal.bam
```

Confirm the merge step runs and outputs match the earlier run before scaling to 150.

## Open decisions needing sign-off

1. **Basecaller model.** v1.5.1's enum caps at `...sup@v4.2.0` (latest release; no
   newer version exists). If production data is `@v4.3.0`, either accept the
   v4.2.0 calibration (confirm with ONT it's valid within R10.4.1 SUP) or await an
   ONT release adding v4.3.0. **Bioinformatics sign-off — affects variant calls.**
2. **evaluate_candidates straggler.** Not fixable via config in v1.5.1 (ClairS
   internal, author TODO). Mitigated by batch parallelism + 72h cap. Optionally
   lower `--clair3_var_pct_full` (sensitivity tradeoff — needs sign-off). Do NOT
   add CPU (measured: doesn't help).

## Cost (POC-derived, per pair)

| | per pair | x150 |
|---|---|---|
| HealthOmics compute+storage (right-sized, merge included) | ~$5.2-5.7 | ~$780-850 |

Merge now runs inside the HealthOmics run (no separate EC2 line item). Long-term
S3 lifecycle for the 2 PB historical dataset is a separate design item.

## Superseded artifacts (kept for reference)

- `merge-workflow/` + `merge_pair.sh` — the earlier standalone-merge / EC2
  approaches. **Superseded** by the internal `merge_tumor` step in `v1_5_1-cloud`.
  Standalone merge workflow `5275733` can be deleted once `v1_5_1-cloud` is validated.
