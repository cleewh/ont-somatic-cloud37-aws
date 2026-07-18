# AWS HealthOmics Performance Report — run 3295679

`colo829-poc-20260704T0552Z-tuned2` · workflow `2590600` version `v1_5_1-tuned2` · region `ap-southeast-1`
Analysis type: manifest-based · Headroom: 20% · Detailed: true · Analyzed 2026-07-04T14:29:54Z

> Full per-shard detail (716 tasks) is preserved in the raw tool output; this file curates the summary, right-sizing, and the CPU-scaling verdict. A machine-readable extract is in `performance-report.json`.

## Run overview

| Field | Value |
| --- | --- |
| Status | CANCELLED (operator-initiated) |
| Creation | 2026-07-04T05:52:59Z |
| Start | 2026-07-04T05:57:00Z |
| Stop | 2026-07-04T14:27:05Z |
| Wall-clock | ~8.50 h (30,604 s) |

## Cost summary (USD)

| Component | USD |
| --- | --- |
| Total estimated cost | 5.4552 |
| — Task cost | 3.7676 |
| — Storage cost | 1.6876 |
| Total potential savings | 0.3061 |

## Resource utilization

| Metric | Value |
| --- | --- |
| Total tasks | 716 |
| Allocated CPUs | 1500.0 |
| Allocated memory | 4397.0 GiB |
| Actual CPU usage | 721.73 |
| Actual memory usage | 664.66 GiB |
| Overall CPU efficiency | 48.1% |
| Overall memory efficiency | 15.1% |
| Wasted CPUs | 830.27 |
| Wasted memory | 5007.34 GiB |

## CPU-scaling verdict (answers "can we use more than 4 CPU?")

### `snv:pileup_variants` — NOT CPU-bound → do NOT add cores
- 4 shards completed and measured; allocated `omics.c.xlarge` (4 CPU / 8 GiB).
- Measured CPU efficiency: **4.3%, 5.7%, 25.5%, 5.7%**. Max CPU usage ≈ **1.03 cores**, max memory ≈ 1.94 GiB.
- Recommended instance: **`omics.c.large` (2 CPU, 4 GiB)** — i.e. right-size DOWN.
- **Verdict:** the tuned 4-CPU bump was wasted; pileup used ~1 core. More CPU does not help and costs more. For production, `cpus=2` is sufficient.

### `snv:evaluate_candidates` — NOT a CPU-throughput problem → finer sharding, not more cores
- **Zero** completed shards produced metrics: the run's single long-pole straggler (shard #341, taskId 9305854) was stuck at ClairS full-alignment on a pathological region with **zero log progress for many hours even at the tuned 4 CPU**, and was cut by the operator's cancel.
- The absence of progress at 4 CPU is itself the measurement: ClairS full-alignment on one hard region is largely sequential, so adding cores per shard won't rescue it.
- **Verdict:** the correct production fix is **finer region sharding** (split pathological full-alignment intervals into smaller chunks so no single shard monopolises the critical path), NOT a larger per-shard `cpus`.

### Companion stages that DO scale
- `sv:severus` peaks at **90.8% CPU** on `omics.m.4xlarge` — genuinely thread-scaling; keep at 16 threads (already set).
- minimap2 mapping + severus are the thread-scaling stages; the ClairS NN-inference processes (`pileup_variants` / `evaluate_candidates`) are the ones that do not.

## Top over-provisioned tasks (right-sizing)

| Task / bucket | Tasks | Avg CPU eff | Avg mem eff | Cost (USD) | Savings (USD) | Current → Recommended |
| --- | --- | --- | --- | --- | --- | --- |
| `omics.m.large` bucket (mostly `snv:clairs_extract_candidates`) | 634 | 52.1% | 11.3% | 2.4429 | 0.2790 | `omics.m.large` → `omics.c.large` |
| `sv:severus` | 1 | 35.2% (peak 90.8%) | 38.9% | 0.6599 | — | `omics.m.4xlarge` → `omics.c.8xlarge` |
| `mod:modkit` | 15 | 36.5% | 11.9% | 0.2807 | 0.0145 | trim smallest shards |
| `snv:pileup_variants` (c.xlarge) | 8 | 24.4% | 12.9% | 0.1392 | 0.0126 | `omics.c.xlarge` → `omics.c.large` |

**Dominant lever:** moving the 634 `omics.m.large` ClairS tasks (only ~11% memory efficiency) to `omics.c.large` recovers ~$0.279/run — the bulk of the $0.3061 total savings.

## Aggregated task highlights

| Process | Instances | Mean runtime | Max runtime | Max CPU | Max mem | Cost (USD) | Recommended |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `snv:clairs_extract_candidates` | 631 | 104.9 s | 227.2 s | 1.65 | 1.97 GiB | 2.4329 | `omics.c.large` |
| `sv:severus` | 1 | 2291 s | 2291 s | 14.53 | 32.31 GiB | 0.6599 | `omics.c.8xlarge` |
| `alignment_stats:mosdepth` | 2 | 2152 s | 2655 s | 1.72 | 2.60 GiB | 0.1373 | `omics.c.xlarge` |
| `alignment_stats:bamstats` | 2 | 894 s | 1103 s | 2.91 | 0.97 GiB | 0.1139 | `omics.c.xlarge` |
| `mod:modkit` | 15 | 144 s | 314 s | 6.42 | 3.66 GiB | 0.2807 | `omics.c.2xlarge` |
| `snv:pileup_variants` | 4 | 48 s | 51 s | 1.03 | 1.94 GiB | 0.0153 | `omics.c.large` |

## Cancellation note

Cancellation was **operator-initiated**, well within the 72 h run-group cap (wall-clock ~8.5 h). Root cause is fully understood — the known `evaluate_candidates` full-alignment straggler on a pathological region — so this is **not a pipeline failure**. `DiagnoseAHORunFailure` was intentionally NOT run (per design § "On CANCELLED": diagnosis is skipped when the cause is already known).
