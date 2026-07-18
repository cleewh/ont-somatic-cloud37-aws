#!/usr/bin/env python3
import json
p = "/Users/cleewh/Desktop/Kiro Projects/ONT-LRS/.kiro/specs/nextflow-poc-on-aws/context.json"
ctx = json.load(open(p))
ctx["cloud26_build"] = {
    "status": "REGISTERED, ACTIVE (not yet run)",
    "registered_version": "v1_5_1-cloud26 (workflow_id=2590600)",
    "definition_zip": "s3://ont-lrs-somatic-poc-apse1-687677765589/workflow-artifacts/wf-somatic-variation-v1.5.1-cloud26.zip",
    "container_registry_map": "registry-1.docker.io -> docker-hub (attached at version creation)",
    "built_from": "reconstructed /tmp/wf-inspect from cloud25 zip, overlaid 3 edited files; diff confirmed ONLY the 3 intended changes vs cloud25.",
    "changes_vs_cloud25": {
        "split_candidates_by_depth (modules/local/wf-clair3-snp.nf)":
            "weight per candidate changed from d^2 to min(d, DSAT)^P (P=2.5, DSAT=73438). Cut when cumulative weight >= B OR count >= M, where B = clairs_target_shard_minutes*60 / clairs_split_cost_k is computed IN-AWK. Emits per-contig manifest (*.split_manifest.tsv) with contig, n_candidates, total weight W, budget, n_shards, and the p/DSAT/k/target constants.",
        "nextflow.config":
            "added clairs_split_weight_exp=2.5, clairs_split_depth_saturation=73438, clairs_split_cost_k=3.603e-11, clairs_target_shard_minutes=5 (all added to schema_ignore_params). clairs_depth_split_budget=3e9 retained as legacy fallback only. cap clairs_max_candidates_per_shard=2000 unchanged.",
        "workflows/wf-somatic-snv.nf":
            "captured split_out; collectFile the manifest to out_dir/clairs_split/clairs_split_manifest.tsv with a header seed."},
    "calibration_source": "cloud26_p_c_calibration + cloud26_generalization_to_other_samples (this context.json)",
    "offline_validation": "scripts/test_cloud26_awk.sh - exact awk on synthetic 60x genome + 30-55kx satellite: weight=min(d,DSAT)^2.5 verified, budget=8.326e12 (=5*60/3.603e-11) verified, manifest 9 tab fields verified, modeled MAX shard time 344s (~5.7min) at MAX/p90=1.00. scripts/sim_shard_deep.py: MAX/p90<=1.24 and worst single candidate<=60s across 30x-200x profiles.",
    "self_consistency_note": "cap 2000 is matched to the 5-min target: worst cap-limited shard (~2000 candidates at <=7050x) ~= 4.4min; worst budget-limited shard ~= target. Neither produces a straggler; raising cap would push cap-limited shards over target.",
    "cost_expectation": "vs cloud25 (fixed 3e9 d^2 budget -> 8539 eval shards, most sub-1min at the 1-min billing floor), cloud26 consolidates deep shards to ~5min each -> far fewer eval tasks -> lower task cost, still straggler-free. Shallow regions stay cap-limited (unchanged).",
    "not_yet_done": "No run launched. cloud25 (9960545) still RUNNING. To validate cloud26 end-to-end: start-run v1_5_1-cloud26 with params_cloud5.json (or params_cloud23.json to also save merged BAM), run group 2793794 (maxRuns 4), cache 6598859. Then read the published clairs_split_manifest.tsv + AnalyzeAHORunPerformance for the true shard count/cost."
}
json.dump(ctx, open(p, "w"), indent=2)
print("context.json updated: cloud26_build (v1_5_1-cloud26 ACTIVE)")
