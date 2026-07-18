#!/usr/bin/env python3
import json
ctx_path = "/Users/cleewh/Desktop/Kiro Projects/ONT-LRS/.kiro/specs/nextflow-poc-on-aws/context.json"
ctx = json.load(open(ctx_path))
ctx["cloud26_p_c_calibration"] = {
    "source_run": "9960545 (cloud25, RUNNING; eval stage COMPLETE, 8539 shards)",
    "method": "Sampled 842 evaluate_candidates shard logs (contig + candidate count n + ClairS 'Total time elapsed'). Depth per budget-cut shard inferred from the algorithm's own d^2 budget cut: Sum(d^2)=B=3e9 -> d=sqrt(B/n). Regressed log(cost/candidate) vs log(depth).",
    "p_estimate": 2.6,
    "p_regression": {"slope_p": 2.61, "r2": 0.885, "n_shards": 314,
        "interpretation": "per-candidate ClairS full-alignment cost ~ depth^2.6 across the operational deep range (~1400x-33000x inferred). Validates the planned d^2.5 weight exponent."},
    "depth_track_facts": {
        "source": "outputs/colo829-cloud6/.../COLO829_tumor.regions.bed.gz (50kb QC windows, tumor merged)",
        "median_depth_x": 98,
        "p99_x": 206, "p999_x": 964, "max_window_x": 38258,
        "deepest_windows": ["chr4:49.10-49.15M=38258x (centromeric satellite)",
            "chr1:143.20-143.25M=33365x", "chrUn_KI270438v1=26615x", "chr22:11.2M=13493x", "chr16:46.35M=12879x"],
        "note": "50kb windows DILUTE 500bp satellite peaks; true peak depth at the worst chr4 candidate is >=54772x (from single-candidate budget cut). Deepest windows map exactly to the n=1 chr4 shards costing 58.56s."},
    "cost_spread_measured": {"shallow_s_per_cand": 0.004, "deep_s_per_cand": 58.56,
        "ratio": 14640, "shallow_depth_x": 98, "deep_depth_x": ">=54772"},
    "saturation_caveat": "Effective FULL-RANGE exponent (98x->satellite) is lower (~1.6) than the deep-range 2.6 because per-candidate cost SATURATES at extreme depth (Clair3/ClairS caps the full-alignment tensor read stack). Consequence: single ultra-deep candidates self-isolate into singleton shards with BOUNDED time (max observed 58.56s ClairS ~1min). This is WHY cloud25's d^2 weighting already produced ZERO stragglers.",
    "c_calibration_for_cloud26": {
        "model": "T_shard = k * Sum(d^pw) over shard candidates; cloud26 per-shard budget = T_target / k",
        "weight_exponent_pw": 2.5,
        "k_median_s_per_unit_Sum_d2.5": 3.603e-11,
        "k_CV_across_shards": 0.51,
        "per_shard_budget_for_10min": 1.665e13,
        "alt_pw_2.0": {"k": 5.913e-9, "cv": 0.56, "budget_10min": 1.015e11},
        "alt_pw_2.6": {"k": 1.285e-11, "cv": 0.52, "budget_10min": 4.670e13},
        "note": "d^2.5 gives the lowest shard-time CV (0.51) but only marginally better than d^2 (0.56). CV~0.5 means ~50% spread; to bound MAX shard time, target a MEAN of ~5min (budget ~8.3e12 for d^2.5) so p90/max stays <=10min, OR keep the candidate-count cap 2000 backstop."},
    "cloud26_implication": {
        "straggler": "Already solved by cloud25 (max eval shard ~1min). cloud26's win is COST, not straggler.",
        "cost_win": "cloud25 budget 3e9 (d^2 units) over-fragmented into thousands of sub-1-min eval shards -> HealthOmics 1-min-floor billing tax. cloud26 targeting ~5-10min shards via calibrated budget uses far FEWER, larger shards -> lower task cost, still no straggler.",
        "recommended": "weight d^2.5, per-sample W=Sum(d^2.5), per-shard budget from T_target/k with T_target ~5min (budget ~8.3e12), cap 2000 backstop, memory*attempt retry, publish manifest."}
}
json.dump(ctx, open(ctx_path, "w"), indent=2)
print("context.json updated with cloud26_p_c_calibration")
print("p =", ctx["cloud26_p_c_calibration"]["p_estimate"], "(R^2=0.885)")
