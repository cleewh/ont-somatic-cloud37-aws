# Design Document: Nextflow POC on AWS HealthOmics (wf-somatic-variation v1.5.1)

## Overview

This design deploys `epi2me-labs/wf-somatic-variation` pinned to Git tag **v1.5.1** as an AWS HealthOmics private workflow in the Singapore region (`ap-southeast-1`) and executes it against a single COLO829 tumor / COLO829BL normal pair. Two ~30x tumor BAMs are staged as a directory and consumed by the pipeline's built-in `xam_ingress` sub-workflow without an intermediate merge on AWS. A compatibility check runs off-HealthOmics before staging to verify that both tumor BAMs share one `SM` tag and one basecaller model. On terminal status, per-task performance metrics (`AnalyzeAHORunPerformance`), a Gantt-style timeline (`GenerateAHORunTimeline`), and — on `FAILED` — a diagnostic bundle (`DiagnoseAHORunFailure`) are captured. A cost extrapolation multiplies the observed per-run cost by 150 and provides a second projection using the right-sized instance recommendations from the performance report.

The design uses the AWS HealthOmics MCP power (`aws-healthomics`) for all HealthOmics- and ECR-related operations. Tool names are called out inline so Phase 4 tasks can map directly onto them.

Code artifacts in this design are configuration JSON (parameter template, container registry map, IAM policies) and a small POSIX shell helper (compatibility check). No general-purpose application language is introduced.

## Architecture

### End-to-end flow

```
+---------------------------------------------------------------------------+
|                       Operator workstation / bastion                      |
|                                                                           |
|  [1] compatibility_check.sh   -->   pass/fail JSON  --+                   |
|      (samtools view -H on 2 tumor BAMs + 1 normal BAM)                    |
|                                                       |                   |
|  [2] Stage inputs to S3   <---------------------------+                   |
|      (only if pass; else run Pre_Merge_Fallback first)                    |
|                                                                           |
|  [3] MCP: aws-healthomics power                                           |
|      - CreatePullThroughCacheForHealthOmics (docker-hub)                  |
|      - CreateContainerRegistryMap                                         |
|      - PackageAHOWorkflow  (Option B: wf-somatic-variation v1.5.1 tar)    |
|      - LintAHOWorkflowBundle (optional preflight)                         |
|      - CreateAHOWorkflow (engine=NEXTFLOW, region=ap-southeast-1)         |
|      - StartAHORun (DYNAMIC, colo829-poc-<ts>)                            |
+-------------------------------------|-------------------------------------+
                                      |
                                      v
+---------------------------------------------------------------------------+
|                    AWS HealthOmics (ap-southeast-1)                       |
|                                                                           |
|  AHO_Workflow (NEXTFLOW, v1.5.1) ---> AHO_Run (DYNAMIC storage)           |
|      |                                                                    |
|      | pulls containers via container_registry_map                        |
|      v                                                                    |
|   ECR PTC: docker-hub/ontresearch/*    <---  registry-1.docker.io         |
|      |                                                                    |
|      | reads S3 inputs, writes S3 outputs                                 |
|      v                                                                    |
|   CloudWatch Logs (engine, manifest, task streams)                        |
+-------------------------------------|-------------------------------------+
                                      |
                                      v
+---------------------------------------------------------------------------+
|                       Operator workstation / bastion                      |
|                                                                           |
|  [4] Poll GetAHORun until terminal status                                 |
|                                                                           |
|  On COMPLETED:                              On FAILED:                    |
|    - AnalyzeAHORunPerformance(headroom=0.20)  - DiagnoseAHORunFailure     |
|    - GenerateAHORunTimeline (SVG to S3)         (escalate to detailed=true|
|    - Cost_Extrapolation_Model.md/.json          if root cause unclear)    |
+---------------------------------------------------------------------------+
```

### Regional and encryption posture

- **Region**: every resource created for the POC — S3 bucket, ECR repositories (pull-through cache prefix), HealthOmics workflow, HealthOmics run, CloudWatch log groups, IAM role — lives in `ap-southeast-1`. The MCP power tools receive `aws_region="ap-southeast-1"` on every call.
- **Encryption**: S3 bucket uses SSE-S3 (AES-256) by default for the POC to avoid provisioning a customer KMS key. If the customer supplies a KMS key ARN in `ap-southeast-1`, the design substitutes SSE-KMS and grants the HealthOmics service role `kms:Decrypt`/`kms:Encrypt`/`kms:GenerateDataKey` on that key.
- **Networking**: HealthOmics default `RESTRICTED` networking mode. VPC mode is out of scope for the POC — no `configuration_name` is provided to `StartAHORun`.

## S3 Bucket Layout

Single POC bucket, `ap-southeast-1`, versioning enabled, SSE-S3, block-public-access on.

```
s3://<poc-bucket>/                                        (ap-southeast-1)
├── inputs/
│   ├── tumor_bams/                                       Tumor_Input_Directory
│   │   ├── colo829_tumor_part1.bam
│   │   ├── colo829_tumor_part1.bam.bai
│   │   ├── colo829_tumor_part2.bam
│   │   └── colo829_tumor_part2.bam.bai
│   ├── normal_bams/                                      Normal_Input_Directory
│   │   ├── colo829bl_normal.bam
│   │   └── colo829bl_normal.bam.bai
│   └── references/
│       ├── GRCh38_no_alt_analysis_set.fna
│       ├── GRCh38_no_alt_analysis_set.fna.fai
│       └── GRCh38_no_alt_analysis_set.dict
├── workflow-artifacts/
│   ├── wf-somatic-variation-v1.5.1.zip                   Definition ZIP (Option B)
│   ├── parameter-template.json                           Derived from nextflow_schema.json@v1.5.1
│   └── container-registry-map.json                       Optional — inline map preferred
├── outputs/
│   └── colo829-poc-<timestamp>/                          run output prefix
│       ├── snv/                                          ClairS SNV VCFs
│       ├── sv/                                           Severus SV VCFs
│       ├── mod/                                          modkit bedMethyl + DMR (DSS)
│       ├── annotation/                                   snpEff annotated VCFs
│       ├── qc/                                           MultiQC report + coverage
│       └── execution/                                    Nextflow timeline/report/trace
└── analysis/
    └── colo829-poc-<timestamp>/
        ├── compatibility-check.json
        ├── performance-report.json                       AnalyzeAHORunPerformance output
        ├── timeline.svg                                  GenerateAHORunTimeline output
        ├── failure-diagnosis.json                        DiagnoseAHORunFailure (if FAILED)
        └── cost-extrapolation.md
```

### S3 bucket configuration

- Region constraint: `LocationConstraint=ap-southeast-1`.
- Bucket policy denies `s3:*` when `aws:SecureTransport = false`.
- Object ownership: `BucketOwnerEnforced` (ACLs disabled).
- Lifecycle: no expiration for the POC (single run).

The reference genome preference for wf-somatic-variation v1.5.1 is a chromosome-labelled build such as **GRCh38 no-alt analysis set** (`chr1..chr22, chrX, chrY, chrM` naming). The upstream demo uses `GCA_000001405.15_GRCh38_no_alt_analysis_set_chr20.fna` — the same "no alt / chr-prefixed" convention. The design stages `.fna`, `.fna.fai`, and `.dict` sidecar files. Reference validation is done during staging by asserting the fai file exists and that its first chromosome column starts with `chr`.

## IAM Role for the HealthOmics Run

A single service role, `omics-poc-run-role`, is created in the POC account and assumed by `omics.amazonaws.com`. The role must have exactly the permissions HealthOmics needs to (a) read inputs, (b) write outputs, (c) pull containers from the ECR pull-through cache prefix, and (d) write CloudWatch Logs.

### Trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "omics.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Permission policy (least privilege for POC scope)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadInputs",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": [
        "arn:aws:s3:::<poc-bucket>/inputs/*",
        "arn:aws:s3:::<poc-bucket>/workflow-artifacts/*"
      ]
    },
    {
      "Sid": "S3WriteOutputs",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": [
        "arn:aws:s3:::<poc-bucket>/outputs/*",
        "arn:aws:s3:::<poc-bucket>/analysis/*"
      ]
    },
    {
      "Sid": "S3ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<poc-bucket>",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["inputs/*", "workflow-artifacts/*", "outputs/*", "analysis/*"]
        }
      }
    },
    {
      "Sid": "ECRAccessForPullThroughCache",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:ap-southeast-1:<account-id>:repository/docker-hub/*"
    },
    {
      "Sid": "ECRAuthToken",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogsWrite",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:CreateLogGroup",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:ap-southeast-1:<account-id>:log-group:/aws/omics/*"
    }
  ]
}
```

`kms:Decrypt` / `kms:GenerateDataKey` on the customer-supplied KMS key ARN is added conditionally if SSE-KMS is chosen at staging time.

## Container Registry Strategy

### Container inventory for wf-somatic-variation v1.5.1

All 8 container images referenced by `nextflow.config` at tag `v1.5.1` are on **Docker Hub** under the `ontresearch/` namespace. This means the entire container surface resolves to a **single upstream registry** (`registry-1.docker.io`), and one pull-through cache rule covers everything.

| Nextflow label            | Docker Hub image                       | Tag (from v1.5.1 `nextflow.config`)                |
| ------------------------- | -------------------------------------- | -------------------------------------------------- |
| _default_                 | `ontresearch/wf-somatic-variation`     | `sha5d62edcc2853ce1fd9afc244ff87e65788c4c596`      |
| `wf_somatic_snv`          | `ontresearch/wf-somatic-snp`           | `sha86599ecdb46472d01e0b7c2704683f6aee8a82dd`      |
| `wf_somatic_snv_to`       | `ontresearch/clairs-to`                | `sha0bed006dfad374401e9410b44d67e6609f7936e9`      |
| `wf_somatic_mod`          | `ontresearch/modkit`                   | `shaa7bf2b62946eeb7646b9b9d60b892edfc3b3a52c`      |
| `dss`                     | `ontresearch/dss`                      | `sha927196d7e068cc49d5a41bcc3db91b9bdf723e7a`      |
| `wf_somatic_sv`           | `ontresearch/wf-somatic-sv`            | `sha4b941d684b3310e8524ce169da2d358a6631fab0`      |
| `wf_common`               | `ontresearch/wf-common`                | `sha72f3517dd994984e0e2da0b97cb3f23f8540be4b`      |
| `snpeff_annotation`       | `ontresearch/snpeff`                   | `sha313729d816872d70b410752001a0e2654eb88807`      |

Source: `https://raw.githubusercontent.com/epi2me-labs/wf-somatic-variation/v1.5.1/nextflow.config` (verified at design time). Any regeneration of this table MUST fetch from the same tagged URL — never `main`, `master`, or `latest`.

### Pull-through cache setup

**Docker Hub requires an authenticated pull-through cache.** Steps (in operator order):

1. Store Docker Hub credentials in Secrets Manager at name `ecr-pullthroughcache/docker-hub` in `ap-southeast-1`. The secret body is `{"username": "<hub-user>", "accessToken": "<hub-access-token>"}`.
2. MCP: `CreatePullThroughCacheForHealthOmics(upstream_registry="docker-hub", ecr_repository_prefix="docker-hub", credential_arn="<secrets-arn>", aws_region="ap-southeast-1")`. This one call:
   - creates the PTC rule (`registry-1.docker.io` → prefix `docker-hub/`),
   - patches the ECR registry permissions policy to let HealthOmics create repos and import images,
   - creates the repository creation template that grants HealthOmics `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` on new repos under the prefix.
3. MCP: `ValidateHealthOmicsECRConfig(aws_region="ap-southeast-1")` — assert the PTC rule shows HealthOmics-usable.
4. Optional warm-up: for each of the 8 images, MCP `CheckContainerAvailability(repository_name="docker-hub/ontresearch/<img>", image_tag="<sha…>", initiate_pull_through=true)`. This triggers a first pull so the run's cold start doesn't have to.

No Quay.io or ECR Public rule is needed — every image is on Docker Hub.

### Container registry map (registryMappings only)

Because there is exactly one upstream registry, the map is a single `registryMappings` entry with no per-image overrides. The map is passed inline to `CreateAHOWorkflow` via `container_registry_map`.

```json
{
  "registryMappings": [
    {
      "upstreamRegistryUrl": "registry-1.docker.io",
      "ecrRepositoryPrefix": "docker-hub"
    }
  ]
}
```

At workflow-creation time, HealthOmics rewrites `ontresearch/wf-somatic-variation:sha…` to `<account>.dkr.ecr.ap-southeast-1.amazonaws.com/docker-hub/ontresearch/wf-somatic-variation:sha…`, and analogously for the other seven images. This map can also be generated fresh via MCP `CreateContainerRegistryMap(include_pull_through_caches=true, ecr_region="ap-southeast-1")` — the tool auto-discovers the `docker-hub` PTC rule and emits an equivalent JSON.

### Coverage assertion (Requirement 5.5)

Every image reference in `nextflow.config@v1.5.1` matches the pattern `ontresearch/<name>:sha<hex>` → upstream host `registry-1.docker.io`. Since the map contains an entry for that upstream, coverage is total. The pre-flight check enumerates the 8 images from the table above and asserts each resolves to an `ap-southeast-1` ECR repo under `docker-hub/ontresearch/*`.

## HealthOmics Workflow Packaging

### Decision: Option B — S3 ZIP via `definition_uri`

Two viable paths were considered:

- **Option A — Git integration (`definition_repository`)**: pass `{connectionArn, fullRepositoryId: "epi2me-labs/wf-somatic-variation", sourceReference: {type: "TAG", value: "v1.5.1"}}` to `CreateAHOWorkflow`. Requires an AWS CodeConnection to GitHub in `ap-southeast-1` in `AVAILABLE` status, which requires an out-of-band OAuth authorization step in the AWS Console. If a suitable connection already exists (`ListCodeConnections(provider_type_filter="GitHub")`), this is the cleanest path.

- **Option B — S3 ZIP (`definition_uri`)**: fetch the v1.5.1 tarball from `https://github.com/epi2me-labs/wf-somatic-variation/archive/refs/tags/v1.5.1.tar.gz`, repack as a ZIP with `main.nf` at the top level, upload to `s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip`, pass `definition_uri="s3://…"` to `CreateAHOWorkflow`. No CodeConnection provisioning, no OAuth step.

**Chosen: Option B.** Rationale:

- POC-first: minimizes external provisioning surface (no OAuth ceremony).
- Reproducibility: the ZIP artifact is content-addressable; its digest can be recorded alongside the run metadata for exact reproduction.
- Version pinning is enforced at fetch time — the code that produces the ZIP MUST use the URL that contains `refs/tags/v1.5.1` literally, and it MUST verify that `manifest.version` inside the unpacked `nextflow.config` equals `v1.5.1` before uploading. Any other value aborts.

Option A remains a documented fallback if the customer prefers Git-tracked provenance and already has a working GitHub CodeConnection.

### Packaging steps (Option B)

1. Fetch `https://github.com/epi2me-labs/wf-somatic-variation/archive/refs/tags/v1.5.1.tar.gz` to a local scratch dir.
2. Extract; the root is `wf-somatic-variation-1.5.1/`.
3. Assert `grep -q "version *= *'v1.5.1'" wf-somatic-variation-1.5.1/nextflow.config`. If not, abort.
4. MCP: `PackageAHOWorkflow(main_file_content="wf-somatic-variation-1.5.1/main.nf", main_file_name="main.nf", additional_files={"nextflow.config": ".../nextflow.config", "lib/": ".../lib/", "subworkflows/": ".../subworkflows/", "modules/": ".../modules/", "bin/": ".../bin/", "nextflow_schema.json": ".../nextflow_schema.json"}, output_path="s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip")`. The tool zips deterministically and uploads.
5. (Optional) MCP: `LintAHOWorkflowBundle(workflow_files="s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip", workflow_format="nextflow"?, main_workflow_file="main.nf")` — note the linter's Nextflow support may be limited; if the tool returns "unsupported format", skip the lint step (Requirements 1.1 and 5.2 do not require linting).
6. MCP: `CreateAHOWorkflow(name="wf-somatic-variation-v1_5_1", engine="NEXTFLOW", definition_uri="s3://<poc-bucket>/workflow-artifacts/wf-somatic-variation-v1.5.1.zip", parameter_template=<see below>, container_registry_map=<see above>, aws_region="ap-southeast-1", tags={"pipeline_version":"v1.5.1","poc":"colo829"})`.

### Parameter template

Derived from `nextflow_schema.json` at tag v1.5.1 and mapped to the customer's on-prem command. Only fields exposed to the HealthOmics parameter surface are listed; internal defaults from `nextflow.config` (such as `ubam_map_threads=8`, `ubam_sort_threads=3`) are re-declared so operators can tune them per run without editing the definition.

```json
{
  "sample_name":               { "description": "Sample label emitted in output filenames" },
  "ref":                       { "description": "S3 URI to reference FASTA (chr-prefixed GRCh38 no-alt)" },
  "bam_tumor":                 { "description": "S3 URI to Tumor_Input_Directory containing 2 tumor BAMs (with .bai). Must end with '/'." },
  "bam_normal":                { "description": "S3 URI to Normal_Input_Directory containing 1 normal BAM (with .bai). Must end with '/'." },
  "snv":                       { "description": "Enable SNV calling (ClairS). Boolean.", "optional": true },
  "sv":                        { "description": "Enable SV calling (Severus). Boolean.", "optional": true },
  "mod":                       { "description": "Enable methylation calling (modkit). Boolean.", "optional": true },
  "diff_mod":                  { "description": "Enable differential methylation (DSS). Boolean.", "optional": true },
  "annotation":                { "description": "Enable snpEff annotation. Boolean.", "optional": true },
  "override_basecaller_cfg":   { "description": "Basecaller model identifier, e.g. dna_r10.4.1_e8.2_400bps_sup@v4.2.0" },
  "ubam_map_threads":          { "description": "Threads for minimap2 mapping (default 8)",              "optional": true },
  "ubam_sort_threads":         { "description": "Threads for samtools sort (default 3)",                 "optional": true },
  "ubam_bam2fq_threads":       { "description": "Threads for samtools bam2fq (default 1)",               "optional": true },
  "severus_threads":           { "description": "Threads for Severus SV caller (default 8)",             "optional": true },
  "haplotype_filter_threads":  { "description": "Threads for ClairS haplotype filter (default 4)",       "optional": true },
  "modkit_threads":            { "description": "Threads for modkit (default 4)",                        "optional": true },
  "dss_threads":               { "description": "Threads for DSS differential methylation (default 1)",  "optional": true }
}
```

Required keys (no `optional: true`): `sample_name`, `ref`, `bam_tumor`, `bam_normal`, `override_basecaller_cfg`. Every schema-required parameter from `nextflow_schema.json@v1.5.1` MUST also appear here — the packaging step reads the schema file and cross-checks; missing keys abort the workflow creation.

## Reference Genome Handling

- **Build**: GRCh38, "no alt analysis set", chromosome-prefixed contigs (`chr1..chr22, chrX, chrY, chrM`). This matches the naming used by the upstream demo dataset for wf-somatic-variation.
- **Layout on S3**: `s3://<poc-bucket>/inputs/references/GRCh38_no_alt_analysis_set.fna` plus sidecar `.fai` and `.dict`.
- **Staging validation** (runs on the operator workstation before staging):
  - `test -s GRCh38_no_alt_analysis_set.fna.fai` — index exists and is non-empty.
  - `head -c 100 GRCh38_no_alt_analysis_set.fna | grep -q "^>chr"` — first contig header starts with `chr`.
  - `awk '{print $1}' GRCh38_no_alt_analysis_set.fna.fai | head -1 | grep -q "^chr"` — fai first column is chr-prefixed.
- **Reference store**: not used for the POC. The pipeline consumes a plain S3 URI. HealthOmics reference stores add operational overhead that isn't justified for a single-pair POC.

## Compatibility Check (off-HealthOmics)

Runs on the operator workstation (Docker + `samtools` >= 1.17) before staging. Emits `analysis/colo829-poc-<ts>/compatibility-check.json` with a `status` of `"pass"` or `"fail"`.

### Extraction

```bash
# For each BAM path in {tumor1, tumor2, normal}:
docker run --rm -v "$PWD:/data" quay.io/biocontainers/samtools:1.17--h00cdaf9_0 \
  samtools view -H /data/"$bam" \
  | awk '
      BEGIN { OFS="\t" }
      /^@RG/ {
        sm=""; ds=""; pl=""
        for (i=2; i<=NF; i++) {
          if ($i ~ /^SM:/) sm = substr($i,4)
          if ($i ~ /^DS:/) ds = substr($i,4)
          if ($i ~ /^PL:/) pl = substr($i,4)
        }
        print "RG", sm, ds, pl
      }
      /^@PG/ {
        pn=""; cl=""
        for (i=2; i<=NF; i++) {
          if ($i ~ /^PN:/) pn = substr($i,4)
          if ($i ~ /^CL:/) cl = substr($i,4)
        }
        print "PG", pn, cl
      }
    '
```

The basecaller model identifier is recovered from **whichever of these appears first**:

1. `@RG DS:` — ONT convention is `DS:basecall_model=dna_r10.4.1_e8.2_400bps_sup@v4.2.0` or similar.
2. `@PG` line with `PN:dorado` and `CL:` containing `--model dna_r10.4.1_e8.2_400bps_sup@v4.2.0`.
3. `@RG PL:ONT` combined with a nearby `basecall_model=` token in `DS:`.

If none of the three yields a token matching `^dna_r10\.4\.1_e8\.2_400bps_sup@v[0-9.]+$`, the extractor sets `basecaller_model="unknown"`, and the compatibility decision downgrades to `fail` with reason `basecaller_unresolved`.

### Decision function

```
pass  iff
    ( |union(SM_tumor1) ∪ union(SM_tumor2)| == 1 )
  AND
    ( basecaller_tumor1 == basecaller_tumor2 == basecaller_normal == "dna_r10.4.1_e8.2_400bps_sup@v4.2.0" )

fail otherwise, with report listing which of:
    - sample_mismatch    (SM sets not singleton or unequal across tumor BAMs)
    - basecaller_mismatch(tumor vs tumor differ, or tumor vs normal differ)
    - basecaller_expected(any BAM's model != dna_r10.4.1_e8.2_400bps_sup@v4.2.0)
    - basecaller_unresolved (no parseable model found)
```

### Output shape

```json
{
  "status": "pass",
  "expected_basecaller": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
  "tumor_bams": [
    { "path": "colo829_tumor_part1.bam", "sm_tags": ["COLO829"], "basecaller_model": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0" },
    { "path": "colo829_tumor_part2.bam", "sm_tags": ["COLO829"], "basecaller_model": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0" }
  ],
  "normal_bam": { "path": "colo829bl_normal.bam", "sm_tags": ["COLO829BL"], "basecaller_model": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0" },
  "mismatches": []
}
```

On `"status": "fail"`, `mismatches` is a non-empty list of the diagnostic tags above with the offending values inline.

### Pre-Merge Fallback (conditional)

Only invoked on `status: "fail"` with `sample_mismatch`. Uses:

```bash
samtools merge -c -p tumor_merged.bam colo829_tumor_part1.bam colo829_tumor_part2.bam
samtools view -H tumor_merged.bam \
  | sed 's/^\(@RG\t.*SM:\)[^\t]*/\1COLO829/' > new_header.sam
samtools reheader new_header.sam tumor_merged.bam > tumor_merged_reheader.bam
samtools index tumor_merged_reheader.bam
```

Staged output: a `tumor_bams/` prefix containing exactly one BAM (`tumor_merged_reheader.bam`) + its `.bai`. The `--bam_tumor` parameter still points at the prefix, not the BAM object. The fallback runs on the operator workstation, **never inside the HealthOmics run**.

## Run Group (safety cap)

_Addresses Requirement 11 in full._

### HealthOmics-native compute lifecycle (context)

AWS HealthOmics is a fully managed compute service; the POC creates **no** long-lived compute resources of its own:

- No EC2 instances are provisioned outside the HealthOmics-managed run.
- No Auto Scaling groups, AWS Batch compute environments, ECS clusters, or EKS node groups are created.
- No always-on Nextflow head node — the Nextflow driver executes inside the HealthOmics-managed run container and terminates together with the run.

When an `AHO_Run` reaches any terminal state (`COMPLETED`, `FAILED`, or `CANCELLED`), HealthOmics automatically releases every underlying compute instance and detaches the DYNAMIC storage. Billing stops at the terminal-state timestamp reported by `GetAHORun`. This behavior is a property of the managed service — the POC does not need to implement post-run teardown.

The Run Group's `maxDuration` cap defined below is a safety net for the "hung task with no terminal event" edge case — the primary compute lifecycle is HealthOmics-managed, not run-group-managed.

**Purpose**: Attach every AHO_Run in this POC to a HealthOmics run group configured with a hard wall-clock cap and a concurrent-run cap. This is the design's mitigation for the "hung task" failure mode (see § "Error Handling"), because a stuck task has no natural terminal event and would otherwise burn compute indefinitely.

**Naming**: `omics-poc-run-group-72h`.

**Configuration**:

- `maxDuration = 4320` minutes (72 hours). Rationale: 2× the customer's on-prem wall-clock (~36h) — generous enough that legitimate cold-start container pulls + slow IO tasks are not spuriously cancelled, tight enough that a genuinely-hung run is capped inside 3 days.
- `maxRuns = 1`. Prevents an operator from starting a parallel POC run against the same group by accident.
- `maxCpus`, `maxGpus`: not set. Rationale: the design already right-sizes via `AnalyzeAHORunPerformance`; adding a CPU cap here would double-throttle.
- Region: `ap-southeast-1`, tags `{"pipeline_version": "v1.5.1", "poc": "colo829"}`.

**Creation tool**: MCP `CreateAHORunGroup(name="omics-poc-run-group-72h", max_duration=4320, max_runs=1, tags={"pipeline_version":"v1.5.1","poc":"colo829"}, aws_region="ap-southeast-1")`.

**Idempotency**: check for existing group via `ListAHORunGroups(name="omics-poc-run-group-72h", aws_region="ap-southeast-1")` before creating. If present with matching config, reuse it; if present with a different `maxDuration`, log a warning and update via `UpdateAHORunGroup`.

**Termination semantics**: when a run's wall-clock exceeds `maxDuration`, HealthOmics transitions the run to terminal status `CANCELLED`. Task compute is released the same way it would be at a normal terminal status. Post-run analysis in § "On CANCELLED" still applies — a CANCELLED run's partial task metrics are still useful for right-sizing (see updated § "On CANCELLED" bullet below).

### Cost-safety guarantee matrix

| Scenario                                               | What terminates compute                                                               | Requirement                            |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------- | -------------------------------------- |
| Run completes normally                                 | HealthOmics on `COMPLETED` transition                                                 | (6.4)                                  |
| Task or workflow fails                                 | HealthOmics on `FAILED` transition                                                    | (6.5)                                  |
| Run stuck / hung > 4320 min (72 h)                     | Run_Group `maxDuration` triggers HealthOmics `CANCELLED`                              | 11.1, 11.3                             |
| Operator wants to abort                                | `aws omics cancel-run --id <run-id> --region ap-southeast-1` → `CANCELLED` transition | (operational — not a spec requirement) |
| Nextflow driver / orchestrator lifecycle               | Driver runs inside the run container; dies with the run                               | (managed service property)             |

Note: manual cancellation is retained as an operator convenience but is NOT tied to Requirement 11.5 (which is now "abort if `run_group_id` is null before `StartAHORun`").

## Run Submission

Single-pair POC run.

### Naming

- Workflow name: `wf-somatic-variation-v1_5_1` (dots aren't allowed in HealthOmics workflow names, so v1.5.1 becomes v1_5_1).
- Run name: `colo829-poc-<UTC_TIMESTAMP>` where `<UTC_TIMESTAMP>` is `YYYYMMDDTHHMMSSZ`. Example: `colo829-poc-20250115T143210Z`.
- Output URI: `s3://<poc-bucket>/outputs/<run-name>/`.

### `StartAHORun` call

MCP tool: `StartAHORun`. The call MUST include `run_group_id` — this is what binds the run to the 72-hour wall-clock cap (see § "Run Group (safety cap)" above).

```
StartAHORun(
  workflow_id       = <returned by CreateAHOWorkflow>,
  role_arn          = arn:aws:iam::<account>:role/omics-poc-run-role,
  name              = "colo829-poc-20250115T143210Z",
  output_uri        = "s3://<poc-bucket>/outputs/colo829-poc-20250115T143210Z/",
  storage_type      = "DYNAMIC",
  run_group_id      = <from CreateAHORunGroup / ListAHORunGroups>,                    # NEW — Requirement 11
  aws_region        = "ap-southeast-1",
  parameters        = {
    "sample_name":              "COLO829",
    "ref":                      "s3://<poc-bucket>/inputs/references/GRCh38_no_alt_analysis_set.fna",
    "bam_tumor":                "s3://<poc-bucket>/inputs/tumor_bams/",
    "bam_normal":               "s3://<poc-bucket>/inputs/normal_bams/",
    "snv":                      true,
    "sv":                       true,
    "mod":                      true,
    "diff_mod":                 true,
    "annotation":               true,
    "override_basecaller_cfg":  "dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
    "ubam_map_threads":         8,
    "ubam_sort_threads":        3,
    "ubam_bam2fq_threads":      1,
    "severus_threads":          8,
    "haplotype_filter_threads": 4,
    "modkit_threads":           4,
    "dss_threads":              1
  }
)
```

### Storage type rationale

`DYNAMIC` is chosen because:

- Total input footprint for a single COLO829/COLO829BL pair (~60x + 30x aligned BAMs + reference) is on the order of ~200–300 GB — well below the multi-TiB threshold where `STATIC` becomes preferable.
- `DYNAMIC` auto-scales scratch and eliminates the need to estimate `storage_capacity` up front, which is desirable for a single-run POC where empirical resource usage is one of the deliverables.
- The MCP tool guidance for `StartAHORun` states: "DYNAMIC is preferred except for runs with very large inputs (TiBs)." COLO829 fits comfortably below that bar.

Run cache is not used for the POC (single run, no reuse benefit). **A run group IS used**, purely as a cost-safety mechanism — see § "Run Group (safety cap)" above. The run group id is REQUIRED per Requirement 11; the submission code MUST refuse to call `StartAHORun` if `run_group_id` is null or empty.

## Post-Run Analysis

### Terminal-status watcher

Poll `GetAHORun(run_id=<id>, aws_region="ap-southeast-1")` at a fixed cadence (default 60 s). Terminal states are `COMPLETED`, `FAILED`, and `CANCELLED`. On terminal status, branch:

### On `COMPLETED`

1. MCP: `AnalyzeAHORunPerformance(run_ids=[<id>], headroom=0.20, detailed=false, aws_region="ap-southeast-1")`.
   - Persist the returned report to `s3://<poc-bucket>/analysis/<run-name>/performance-report.json`.
   - If any task recommendation is inconclusive, re-run with `detailed=true` and persist the enriched output alongside.
2. MCP: `GenerateAHORunTimeline(run_id=<id>, time_unit="hr", region="ap-southeast-1", output_format="svg", output_path="s3://<poc-bucket>/analysis/<run-name>/timeline.svg", theme="light", aws_region="ap-southeast-1")`.
3. Compute the cost extrapolation (below).

### On `FAILED`

1. MCP: `DiagnoseAHORunFailure(run_id=<id>, detailed=false, aws_region="ap-southeast-1")`. Persist to `analysis/<run-name>/failure-diagnosis.json`.
2. If `recommendations` in the response are non-specific or `failureReason` is generic, re-run with `detailed=true` and persist the enriched bundle.
3. Still run `AnalyzeAHORunPerformance` and `GenerateAHORunTimeline` — partial task data on a failed run is still useful for right-sizing.

### On `CANCELLED`

Record the cancellation reason from `GetAHORun`. If the cancellation was due to the Run_Group `maxDuration` cap (indicated by the failure/cancellation reason), still run `AnalyzeAHORunPerformance` and `GenerateAHORunTimeline` — partial task data from a duration-capped run is the most useful signal for identifying which task caused the hang. Skip `DiagnoseAHORunFailure` because the cause is known (duration cap).

### Cost extrapolation

Persist `analysis/<run-name>/cost-extrapolation.md` (human-readable) and `.json` (machine-readable) containing:

- `per_run_cost_observed` — extracted from the `Performance_Report` (`AnalyzeAHORunPerformance` returns per-task and total cost).
- `pair_count = 150`.
- `total_cost_observed = per_run_cost_observed * 150`.
- `per_run_cost_rightsized` — sum of the right-sized instance costs recommended in the performance report at the specified `headroom` (defaults `0.20`).
- `total_cost_rightsized = per_run_cost_rightsized * 150`.
- `region = "ap-southeast-1"`, `storage_type = "DYNAMIC"`, `pipeline_version = "v1.5.1"`, `headroom = 0.20`.
- `notes`: enumerate assumptions — no re-run overhead, no data-transfer premium beyond `ap-southeast-1`, no long-term storage tail beyond the outputs bucket.

```json
{
  "region": "ap-southeast-1",
  "storage_type": "DYNAMIC",
  "pipeline_version": "v1.5.1",
  "headroom": 0.20,
  "pair_count": 150,
  "per_run_cost_observed_usd": <float>,
  "total_cost_observed_usd": <float>,
  "per_run_cost_rightsized_usd": <float>,
  "total_cost_rightsized_usd": <float>,
  "notes": ["single-region", "no cross-AZ transfer premium beyond default"]
}
```

## Output Artifacts

At the end of a successful POC run, the following artifacts exist:

| Artifact                          | S3 location                                                      | Producer                              |
| --------------------------------- | ---------------------------------------------------------------- | ------------------------------------- |
| Somatic SNV VCFs                  | `outputs/<run-name>/snv/*.vcf.gz`                                | wf-somatic-variation (ClairS)         |
| Somatic SV VCFs                   | `outputs/<run-name>/sv/*.vcf.gz`                                 | wf-somatic-variation (Severus)        |
| Methylation bedMethyl             | `outputs/<run-name>/mod/*.bed.gz`                                | wf-somatic-variation (modkit)         |
| Differential methylation (DMR)    | `outputs/<run-name>/mod/dss/*`                                   | wf-somatic-variation (DSS)            |
| Annotated VCFs                    | `outputs/<run-name>/annotation/*.vcf.gz`                         | wf-somatic-variation (snpEff)         |
| MultiQC + QC reports              | `outputs/<run-name>/qc/multiqc_report.html`, `qc/*`              | wf-somatic-variation                  |
| Nextflow execution reports        | `outputs/<run-name>/execution/{timeline,report,trace}.*`         | wf-somatic-variation                  |
| Compatibility check               | `analysis/<run-name>/compatibility-check.json`                   | operator workstation (pre-run)        |
| Performance report                | `analysis/<run-name>/performance-report.json`                    | `AnalyzeAHORunPerformance`            |
| Timeline visualization            | `analysis/<run-name>/timeline.svg`                               | `GenerateAHORunTimeline`              |
| Failure diagnosis (conditional)   | `analysis/<run-name>/failure-diagnosis.json`                     | `DiagnoseAHORunFailure`               |
| Cost extrapolation                | `analysis/<run-name>/cost-extrapolation.{md,json}`               | operator workstation (post-run)       |

## Components and Interfaces

This POC has no long-lived application components — it is a one-shot orchestration flow driven by MCP tool invocations against AWS-managed services. The "components" in this design are the discrete artifacts and helpers that the flow creates and consumes; the "interfaces" are the AWS APIs (via the aws-healthomics MCP power) and the JSON shapes those artifacts carry.

### Component inventory

| Component                        | Kind                          | Owner              | Interface / contract                                                                                                                                                                       |
| -------------------------------- | ----------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `compatibility_check.sh`         | POSIX shell helper            | operator workstation | Inputs: local BAM paths (tumor1, tumor2, normal), expected basecaller constant. Output: `compatibility-check.json` (schema in _Data Models_). Exit code 0 on `pass`, 1 on `fail`.       |
| `pre_merge_fallback.sh`          | POSIX shell helper (optional) | operator workstation | Inputs: two tumor BAM paths, target `SM` value. Output: single merged + reheadered BAM + `.bai`. Invoked only on compatibility `fail: sample_mismatch`.                                    |
| `parameter-template.json`        | HealthOmics parameter template | packaging step     | Interface: keys and `optional` flags derived from `nextflow_schema.json@v1.5.1` plus the four mandatory keys `sample_name`, `ref`, `bam_tumor`, `bam_normal`, `override_basecaller_cfg`.  |
| `container-registry-map.json`    | HealthOmics container registry map | packaging step     | Interface: `{registryMappings: [{upstreamRegistryUrl, ecrRepositoryPrefix}]}`. Exactly one entry — `registry-1.docker.io` → `docker-hub`. Passed inline via `container_registry_map`.  |
| `wf-somatic-variation-v1.5.1.zip`| HealthOmics workflow ZIP      | packaging step     | Interface: `definition_uri` argument to `CreateAHOWorkflow`. Contains `main.nf`, `nextflow.config`, `nextflow_schema.json`, `lib/`, `subworkflows/`, `modules/`, `bin/` from tag v1.5.1.  |
| `omics-poc-run-role`             | IAM role                      | operator (one-time) | Interface: trust policy for `omics.amazonaws.com`; permission policy scoped to the POC bucket + `docker-hub/*` ECR prefix + `logs:*` on `/aws/omics/*`. ARN passed as `role_arn` to `StartAHORun`. |
| Docker Hub PTC rule              | ECR pull-through cache        | operator (one-time) | Interface: `registry-1.docker.io` → prefix `docker-hub/`; credentials via `ecr-pullthroughcache/docker-hub` Secrets Manager entry.                                                        |
| POC bucket                       | S3 bucket                     | operator (one-time) | Interface: layout in _S3 Bucket Layout_. `ap-southeast-1`, SSE-S3, `BucketOwnerEnforced`, TLS-only bucket policy.                                                                        |
| AHO_Workflow                     | HealthOmics private workflow  | packaging step     | Interface: created by `CreateAHOWorkflow`; addressed thereafter by `workflow_id`. Engine `NEXTFLOW`, region `ap-southeast-1`.                                                             |
| Run_Group                        | HealthOmics run group         | operator (one-time) | Interface: created via `CreateAHORunGroup` (`omics-poc-run-group-72h`); referenced by `run_group_id` in `StartAHORun`. `maxDuration=4320` min (72 h), `maxRuns=1`. Region `ap-southeast-1`. |
| AHO_Run                          | HealthOmics run               | run submission     | Interface: created by `StartAHORun`; addressed by `run_id`. Terminal states: `COMPLETED`, `FAILED`, `CANCELLED`.                                                                          |
| Terminal-status watcher          | polling loop                  | operator workstation | Interface: `GetAHORun(run_id)` at fixed cadence. Branches on terminal status into the post-run flow.                                                                                     |
| Post-run analysis bundle         | JSON + SVG + markdown         | post-run flow      | Interface: `analysis/<run-name>/{performance-report.json, timeline.svg, failure-diagnosis.json, cost-extrapolation.{md,json}, compatibility-check.json}`. Schemas in _Data Models_.       |

### Interaction contract

Every step reads and writes through these two channels only:

1. **S3** (POC bucket, `ap-southeast-1`) — for all payload data (inputs, workflow ZIP, outputs, analysis artifacts).
2. **AWS HealthOmics + ECR APIs** (via the `aws-healthomics` MCP power, `aws_region="ap-southeast-1"`) — for all control-plane operations.

No component talks to any other AWS region, no component reads or writes outside its allocated S3 prefix, and no component depends on an in-memory shared state — the entire flow is idempotent given a fixed `<UTC_TIMESTAMP>` and can be re-driven end-to-end from the run-name onward.

## MCP Tool Map

Quick reference — each design step, the MCP tools it invokes, and the requirement it satisfies.

| Design step                                       | MCP tools                                                                                       | Requirements     |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------- |
| ECR pull-through cache for Docker Hub             | `CreatePullThroughCacheForHealthOmics`, `ValidateHealthOmicsECRConfig`, `ListPullThroughCacheRules` | 5.3, 5.5, 10.5 |
| Warm-up container cache                           | `CheckContainerAvailability` (per image)                                                        | 5.3              |
| Generate/verify registry map                      | `CreateContainerRegistryMap`                                                                    | 1.2, 5.3, 5.4    |
| Package v1.5.1 definition to S3 ZIP               | `PackageAHOWorkflow`                                                                            | 1.1              |
| Optional pre-flight lint                          | `LintAHOWorkflowBundle`                                                                         | (best-effort)    |
| Create the workflow                               | `CreateAHOWorkflow`                                                                             | 1.1, 5.1, 5.2, 5.4, 5.6, 10.3 |
| Create/verify the Run_Group safety cap            | `CreateAHORunGroup`, `ListAHORunGroups`, `UpdateAHORunGroup`, `GetAHORunGroup`                  | 11.1, 11.2, 11.4 |
| Start the single POC run                          | `StartAHORun` (with `run_group_id`)                                                             | 2.2, 2.5, 6.1, 6.2, 6.3, 10.4, 11.2, 11.5 |
| Poll for terminal status                          | `GetAHORun`                                                                                     | 6.4, 6.5, 7.1, 7.3 |
| Performance report + right-sizing                 | `AnalyzeAHORunPerformance`                                                                      | 7.1, 7.2, 8.1, 8.2 |
| Timeline visualization                            | `GenerateAHORunTimeline`                                                                        | 7.3, 7.4         |
| Failure diagnosis                                 | `DiagnoseAHORunFailure`                                                                         | 6.5              |
| (Fallback) Git-integration path                   | `ListCodeConnections`, `CreateCodeConnection`, `GetCodeConnection`                              | 1.1 (alternate)  |

## Data Models

Only two schemas are introduced by this design (everything else is pipeline output or HealthOmics-native).

### `compatibility-check.json`

```json
{
  "status":               "pass" | "fail",
  "expected_basecaller":  "dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
  "tumor_bams": [
    { "path": "<basename>", "sm_tags": ["<string>", ...], "basecaller_model": "<string>|unknown" }
  ],
  "normal_bam":  { "path": "<basename>", "sm_tags": ["<string>", ...], "basecaller_model": "<string>|unknown" },
  "mismatches":  [ "sample_mismatch" | "basecaller_mismatch" | "basecaller_expected" | "basecaller_unresolved" ]
}
```

### `cost-extrapolation.json`

Shape given above under Post-Run Analysis.

## Error Handling

| Failure mode                                          | Detection                                                       | Action                                                                                                                    |
| ----------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Compatibility check `fail: sample_mismatch`           | Local check                                                     | Run Pre-Merge Fallback, then re-stage and re-run compatibility check (must now pass).                                     |
| Compatibility check `fail: basecaller_mismatch/expected` | Local check                                                  | Abort — POC input constraint violated; requires re-basecalling upstream, not merging.                                     |
| Compatibility check `fail: basecaller_unresolved`     | Local check                                                     | Escalate to operator with the raw header dump; do not proceed to staging.                                                 |
| PTC rule creation fails (missing DH secret)           | `CreatePullThroughCacheForHealthOmics` error                    | Prompt for Docker Hub credentials; create the Secrets Manager entry; retry.                                               |
| Container coverage gap (an image not resolvable)      | `CheckContainerAvailability` returns `healthomics_accessible=false` | Abort workflow creation (Requirement 5.5). Emit the offending image name for the operator.                            |
| Workflow version mismatch (fetched ref not v1.5.1)    | `grep -q "version *= *'v1.5.1'" nextflow.config` fails          | Abort with `version_mismatch` before ZIP upload (Requirement 1.4).                                                        |
| Run enters `FAILED`                                   | `GetAHORun` status                                              | `DiagnoseAHORunFailure(detailed=false)`; if root cause unclear, escalate to `detailed=true`.                              |
| Run wall-clock exceeds Run_Group `maxDuration` cap    | `GetAHORun` status transitions to `CANCELLED` with duration-cap reason | Still run `AnalyzeAHORunPerformance` + `GenerateAHORunTimeline` (partial metrics identify the hung task). Do NOT run `DiagnoseAHORunFailure` — cause is known. Alert the operator to inspect the timeline for the task that consumed the runway. |
| Reference file missing `.fai` / non-chr contigs       | Local staging validation                                        | Abort staging; require operator to supply a chr-prefixed no-alt build.                                                    |

## Correctness Properties

_A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees._

The POC is primarily an orchestration exercise across AWS-managed services, so most acceptance criteria are one-shot configuration invariants (verified by SMOKE tests) or external-service behaviors (verified by INTEGRATION tests). Only the compatibility-check logic and the optional pre-merge fallback carry universal properties over variable input.

### Property 1: Compatibility check decision correctness

For any set of BAM headers derived from the two tumor BAMs and one normal BAM, the compatibility-check function SHALL emit `status="pass"` **if and only if** (a) the union of `SM` tag values across both tumor BAMs is a singleton set, **and** (b) the basecaller model identifier extracted from each of the three BAM headers equals the expected constant `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`. When `status="fail"`, the `mismatches` list SHALL contain at least one tag from `{sample_mismatch, basecaller_mismatch, basecaller_expected, basecaller_unresolved}` that names an actual violation, and every named violation SHALL correspond to a demonstrable inequality in the input headers.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

### Property 2: Pre-merge fallback unifies the sample tag (optional)

For any pair of tumor BAM headers whose `@RG` `SM` tags together form a non-singleton set, executing the Pre-Merge Fallback (`samtools merge` followed by `samtools reheader` with a rewritten `SM` value) SHALL produce a single BAM whose `@RG` `SM` values form the singleton set `{chosen_sm}`, where `chosen_sm` is the value supplied to the `sed` reheader step. The output BAM SHALL still contain every alignment record present in the union of the two input BAMs (i.e., no records are dropped or duplicated by the merge+reheader).

**Validates: Requirements 4.2**

_Note: Property 2 exercises the fallback path only. For COLO829 POC inputs the compatibility check is expected to pass, so Property 2's implementation is marked optional in the task list. If it is skipped, Requirement 4.2 is covered by the design assertion alone — the fallback path is documented but not empirically verified until it is triggered._

## Testing Strategy

Because the POC operates almost entirely through AWS-managed services and the aws-healthomics MCP power, the appropriate test mix is heavily weighted toward SMOKE/INTEGRATION checks with a narrow property-based-test surface:

- **Property tests (2)** cover the compatibility-check decision function (mandatory) and the pre-merge fallback (optional). Minimum 100 generated inputs per property. Test tags: `Feature: nextflow-poc-on-aws, Property 1: Compatibility check decision correctness` and `Feature: nextflow-poc-on-aws, Property 2: Pre-merge fallback unifies the sample tag`.
- **Example / edge-case tests** cover the version-mismatch abort (Requirement 1.4) and the cost extrapolation arithmetic (Requirements 9.1, 9.3). One or two examples each.
- **SMOKE tests** cover every one-shot configuration invariant: region equality, workflow engine type, storage type, IAM role permissions, S3 layout, parameter template completeness, container map coverage, and the presence of post-run analysis artifacts.
- **INTEGRATION tests** exercise the end-to-end run itself — a single COLO829 pair is the integration test for Requirements 6.4, 7.2, and 8.1 (right-sizing correctness delegated to `AnalyzeAHORunPerformance`).

No unit test suite for the pipeline internals is created — that's upstream's responsibility and is out of scope for the POC.
