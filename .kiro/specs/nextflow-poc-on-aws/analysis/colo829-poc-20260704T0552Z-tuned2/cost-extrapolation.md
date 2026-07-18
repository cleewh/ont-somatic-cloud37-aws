# Cost Extrapolation — COLO829 POC → 150-pair production

| Parameter | Value |
| --- | --- |
| Run analyzed | `3295679` (`colo829-poc-20260704T0552Z-tuned2`, workflow version `v1_5_1-tuned2`) |
| Region | `ap-southeast-1` |
| Storage type | `DYNAMIC` |
| Pipeline version | `v1.5.1-tuned` |
| Headroom | 0.20 |
| Pair count | 150 |
| Terminal status | CANCELLED (operator-initiated) |
| Wall-clock | ~8.50 h (05:57:00Z → 14:27:05Z) |

## Observed per-run cost (measured)

| Component | USD |
| --- | --- |
| Task (compute) | 3.7676 |
| Storage (DYNAMIC) | 1.6876 |
| **Total per run** | **5.4552** |
| Right-sizing savings available | −0.3061 |
| **Rightsized per run** | **5.1491** |

> **Cancelled-run caveat.** This run finished essentially the entire pipeline EXCEPT one straggler `snv:evaluate_candidates` shard (#341) and the downstream SNV merge/annotation tail. The observed $5.4552/run therefore **slightly under-estimates a 100%-complete run**. Treat both projections below as a lower bound.

## Two projections to 150 pairs

### a. Conservative / as-run
Observed per-run cost × 150, tuned v1.5.1 exactly as configured, no right-sizing.

```
5.4552 × 150 = $818.28
```

Excludes the merge pre-step and the unfinished straggler + merge tail (see caveat).

### b. Optimized
Apply the performance-report right-sizing (drop the 634 over-provisioned `omics.m.large` ClairS tasks → `omics.c.large`; `pileup_variants` `c.xlarge` → `c.large`; trim the smallest `modkit` shards), plus finer SNV sharding to kill the `evaluate_candidates` straggler runway and a spot-instance tumor merge.

```
5.1491 × 150 = $772.37
```

The right-sizing delta is modest (~$46 across 150 pairs) because ClairS shards already run on inexpensive instances. The bigger production win is **wall-clock** (removing the multi-hour straggler tail via finer sharding) and **the merge pre-step moving to spot**, not the per-run compute line.

## Cost centres (per run)

| Stage | Aggregate cost | Note |
| --- | --- | --- |
| `snv:clairs_extract_candidates` (631 shards) | $2.4329 | On `omics.m.large`; ~11% memory efficiency → right-size to `omics.c.large`. |
| `sv:severus` (1) | $0.6599 | Single most expensive task; peaks 90.8% CPU → genuinely thread-bound, keep large. |
| `mod:modkit` (15) | $0.2807 | Mixed efficiency; trim smallest shards. |
| `alignment_stats:mosdepth` (2) | $0.1373 | |
| `snv:pileup_variants` (4) | $0.0153 | 4-CPU allocation wasted (≤25% CPU eff). |
| Storage (DYNAMIC) | $1.6876 | |

## Notes / assumptions

- **Cancelled-run caveat** — observed cost is a near-complete run minus one shard + merge tail; a full run costs marginally more.
- **Tumor merge is a required per-pair pre-step** — wf-somatic-variation v1.5.1 needs a single `bam_tumor` file (HealthOmics can't stage S3 directory/glob URIs), so the ~292 GB merge of the two tumor BAMs must run before each HealthOmics submission. Budget it separately and run it on **spot** EC2 (~30–60 min per pair); it is NOT in the numbers above.
- **`evaluate_candidates` straggler needs finer region sharding, not more CPU** — measured `pileup_variants` CPU efficiency at 4 CPU was 4–25% (≈1 core used). More cores per shard waste money; split pathological full-alignment intervals instead.
- No re-run overhead; no cross-AZ/region transfer premium beyond `ap-southeast-1` defaults; no long-term storage tail beyond the outputs bucket; single-region pricing at analysis time (no committed-use discounts or credits).
- A run cache (`6598859`, `CACHE_ALWAYS`) is attached — production re-runs reusing completed tasks would cost less than these projections.
