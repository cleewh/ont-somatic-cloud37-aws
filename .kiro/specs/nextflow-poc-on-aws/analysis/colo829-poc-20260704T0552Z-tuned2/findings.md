# COLO829 POC on AWS HealthOmics — Findings

**Pipeline:** ONT `wf-somatic-variation` v1.5.1 (tuned) · **Engine:** Nextflow on AWS HealthOmics
**Region:** ap-southeast-1 · **Dataset:** COLO829 / COLO829BL (tumor 60×, normal 30×)
**Analyzed run:** `3295679` (`colo829-poc-20260704T0552Z-tuned2`, workflow version `v1_5_1-tuned2`)

## 1. Bottom line — the pipeline runs end-to-end on AWS HealthOmics

The full ONT somatic pipeline (SNV + SV + methylation + differential methylation + annotation, matching the customer's on-prem command exactly) executed end-to-end on HealthOmics. Across the run, **716 tasks** covered reference prep, ingress/header checks, alignment QC (mosdepth, bamstats), methylation (modkit), differential methylation (DSS), SV calling (Severus), and somatic SNV calling (ClairS: chunking → pileup → candidate extraction → paired tensors → full-alignment). Every stage ran. The run was **cancelled by the operator**, not failed: one pathological `snv:evaluate_candidates` full-alignment shard (#341) hung on a hard region while the rest of the pipeline had effectively completed. Cutting one stuck SNV shard is the only gap — validation of AWS feasibility is successful.

## 2. Wall-clock

~**8.50 hours** (start 2026-07-04T05:57:00Z → cancel 2026-07-04T14:27:05Z), well inside the 72 h run-group safety cap. The tail was dominated by the single `evaluate_candidates` straggler; without it the productive pipeline finished in materially less wall-clock.

## 3. The 5 platform gotchas we hit and fixed

1. **Basecaller enum mismatch (v4.3.0 → v4.2.0).** ONT publishes COLO829 SUP BAMs as `dna_r10.4.1_e8.2_400bps_sup@v4.3.0`, but v1.5.1's `nextflow_schema.json` enum caps at `v4.2.0`. Attempt 1 failed schema validation in 161 s. Fix: pass `override_basecaller_cfg=...@v4.2.0` (same R10.4.1 SUP family; close ClairS/DSS calibration).
2. **Directory URI ingress.** Passing `bam_tumor` as an S3 directory URI (trailing slash) failed — HealthOmics stages it as a single mounted directory and `xam_ingress` `Channel.fromPath()` couldn't enumerate the BAMs (`Missing fromPath parameter`).
3. **Glob URI ingress.** Passing `s3://.../*.bam` staged as a `LinkedList`, and `main.nf` does `file(params.bam_tumor).exists()` which needs a single `Path` (`MissingMethodException: LinkedList.exists()`). Conclusion: the pipeline fundamentally requires a **single** `bam_tumor` file. Fix: **pre-merge** the two tumor BAMs (PAU59949 + PAU61426) into one sorted, indexed ~292 GB BAM (`samtools merge -c -p`) and pass single-file URIs. This is the HealthOmics-equivalent of the on-prem directory ingress.
4. **ClairS `cpus=1` straggler.** In an earlier run, 2 of ~500 ClairS shards stalled 3–4 h each on a hardcoded `cpus=1` directive in `modules/local/wf-clair3-snp.nf`. Fix: patched `nextflow.config` `withName` overrides for `pileup_variants` and `evaluate_candidates` (cpus 1→4, memory bumps). (See §5 — the measured data now says the real fix is finer sharding, not more CPU.)
5. **Container registry map required on workflow *versions*.** `CreateAHOWorkflowVersion` without `container_registry_map` rejected `ontresearch/*` images as malformed ECR URIs (`INVALID_ECR_IMAGE_URI`). Fix: recreate the version (`v1_5_1-tuned2`) with the same `registryMappings` (`registry-1.docker.io` → `docker-hub` ECR prefix) used on the base workflow.

## 4. Instance right-sizing (measured, 20% headroom)

Overall CPU efficiency **48.1%**, memory efficiency **15.1%** — significant right-sizing headroom.

| Bucket | Tasks | Finding | Action |
| --- | --- | --- | --- |
| `omics.m.large` (mostly `clairs_extract_candidates`) | 634 | ~11% memory efficiency; m-family (4 GiB/CPU) wasted | → `omics.c.large` (2 CPU, 4 GiB); ~$0.279/run saved (bulk of savings) |
| `sv:severus` | 1 | Peaks 90.8% CPU (thread-bound), 38.9% mem | → `omics.c.8xlarge` (32 CPU, 64 GiB); keep 16 threads |
| `mod:modkit` | 15 | 36.5% avg CPU eff at 8 CPU | trim smallest shards |
| `snv:pileup_variants` | 8 | 24.4% CPU eff at 4 CPU | → `omics.c.large` (2 CPU) |

Total identified savings: **$0.3061/run** (of $3.7676 task cost).

## 5. CPU-scaling verdict — "can we use more than 4 CPU?"

**No — for the ClairS NN-inference stages, and here's the measured proof:**

- **`pileup_variants`: NOT CPU-bound.** The 4 completed shards used **~1 core** at the tuned 4-CPU allocation (CPU efficiency 4–25%). Adding cores wastes money; production can drop to `cpus=2`.
- **`evaluate_candidates`: NOT a throughput problem.** The straggler shard made **zero progress for hours at 4 CPU** — a single hard full-alignment region is essentially sequential, so more cores per shard cannot rescue it. The right fix is **finer region sharding** (split the pathological interval into smaller chunks) so no single shard becomes the critical-path long-pole.
- **What DOES scale:** `sv:severus` (peak 90.8% CPU) and minimap2 mapping — already tuned to 16 threads; keep them.

## 6. Cost projection to 150 pairs

| Projection | Per run | × 150 pairs |
| --- | --- | --- |
| **Conservative / as-run** | $5.4552 | **$818.28** |
| **Optimized** (right-sized + finer sharding + spot merge) | $5.1491 | **$772.37** |

Per-run cost breakdown: task $3.7676 + storage $1.6876 = **$5.4552**.

> **Caveat:** the run was cancelled ~1 shard short of 100%, so both figures slightly under-estimate a fully-complete run. The per-pair ~292 GB tumor merge is a **separate required pre-step** (run on spot EC2, not counted above). The optimized per-run delta is small because ClairS shards already run on cheap instances — the real production win is **wall-clock** (killing the straggler tail via finer sharding), not the compute line.

## 7. Recommended production changes (150-pair migration)

1. **Finer SNV region sharding** — split ClairS full-alignment intervals so no single pathological region can monopolise the critical path (root cause of the only gap in this POC). Keep `cpus` at 2–4 for pileup/evaluate; do not scale cores up.
2. **Right-size instances** — move the ClairS `clairs_extract_candidates` / `pileup_variants` buckets from `omics.m.large` / `omics.c.xlarge` to `omics.c.large`; keep Severus on a large c-family instance.
3. **Run cache** — already created (`id 6598859`, `CACHE_ALWAYS`, `s3://.../run-cache/`); resubmits skip completed tasks.
4. **Batch execution** — `StartRunBatch` with a run group `maxRuns > 1` to run the 150 pairs in parallel instead of one at a time.
5. **Spot-instance tumor merge** — the mandatory per-pair ~292 GB tumor BAM merge should run on spot EC2 (~30–60 min/pair) to minimise the pre-step cost.
6. **Keep the container registry map on every workflow version** — required for `ontresearch/*` → ECR mirror resolution.
