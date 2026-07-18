#!/usr/bin/env python3
import json
p = "/Users/cleewh/Desktop/Kiro Projects/ONT-LRS/.kiro/specs/nextflow-poc-on-aws/context.json"
ctx = json.load(open(p))
ctx["cloud26_generalization_to_other_samples"] = {
    "question": "Does the self-tuning split work for other/deeper depth profiles?",
    "answer": "Yes, validated.",
    "why_generalizes": [
        "p (~2.6) and c/k are ALGORITHM+INSTANCE constants (tensor build + NN + fixed instance), NOT sample properties -> same for all 150 pairs.",
        "W = Sum(depth^2.5) is computed PER SAMPLE from that sample's own 500bp mosdepth track -> auto-captures coverage level, centromere/satellite intensity, amplifications.",
        "budget = T_target/k divides that sample's W into ~equal-time shards; deeper sample -> larger W -> more shards, each still ~T_target."],
    "saturation_is_the_key_robustness_fact": {
        "measured": "552 single-candidate (n=1) eval shards from cloud25: p50=15.2s, p90=51.2s, p99=58.6s, MAX=59.0s. p90->max spread only 1.15x.",
        "meaning": "Single-candidate ClairS full-alignment cost SATURATES at a ~60s ceiling (Clair3/ClairS downsamples the tensor read stack at high depth). The deepest chr4/chr22/chr1 satellite candidates (38k-55k x) all cost ~1 min.",
        "consequence": "The smallest indivisible unit (one candidate) is time-bounded (<=~60s) REGARDLESS of depth. Therefore NO depth profile can create an un-splittable multi-hour straggler. This is stronger than any splitting heuristic."},
    "deep_sim_result": {
        "script": "scripts/sim_shard_deep.py (uses MEASURED c_cand=1.197e-11, p=2.61, CEIL=60s, weight d^2.5, k=3.603e-11, T_target=5min, cap=2000)",
        "profiles_tested": "30x, 60x, 90x, 120x, 150x, 200x+90kx-satellite, 60x-massive-centromere, bimodal-40x+amp",
        "MAX_over_p90_shard_time": "1.00-1.24 across ALL profiles -> no straggler",
        "worst_single_candidate": "<= 60s in every profile (hits ceiling only at >73kx)",
        "shard_count_scaling": "87 (30x) -> 19008 (200x extreme): scales with GENUINE workload; cost tracks real compute, per-shard time stays bounded."},
    "refinement_weight_cap": {
        "idea": "Cap weight at the saturation depth D_SAT~73438x: w = min(depth, D_SAT)^2.5, since cost stops growing past D_SAT.",
        "benefit": "Avoids over-fragmenting pathologically deep loci (>73kx). 200x-extreme: 19008 -> 16964 shards (-11%).",
        "verdict": "Only matters for satellite peaks >73kx (beyond COLO829's ~55kx). Cheap to add as insurance for the 150-pair campaign; no effect on normal samples."},
    "honest_caveats": [
        "p and CEIL measured on omics.c/r eval instances at cloud25 sizing; if evaluate_candidates instance type/size changes, recalibrate c and CEIL (p and the SHAPE are stable).",
        "500bp mosdepth must resolve the sample's peaks; if a future sample has sub-500bp spikes, they could be under-weighted, but the 60s single-candidate ceiling still caps any resulting shard.",
        "Cost (not runtime) grows with depth - a 200x sample legitimately costs more compute; the split bounds TIME per shard, not total spend."]
}
json.dump(ctx, open(p, "w"), indent=2)
print("wrote cloud26_generalization_to_other_samples; D_SAT=73438x, CEIL=60s")
