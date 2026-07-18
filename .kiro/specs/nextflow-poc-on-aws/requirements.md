# Requirements Document

## Introduction

This feature delivers a proof-of-concept (POC) deployment of the `epi2me-labs/wf-somatic-variation` Nextflow pipeline at pinned version **v1.5.1** on AWS HealthOmics in the Singapore region (`ap-southeast-1`). The POC processes a matched tumor/normal Oxford Nanopore Technologies (ONT) long-read sequencing pair from the public COLO829 / COLO829BL dataset, using ~60x tumor coverage delivered as two ~30x BAMs and ~30x normal coverage delivered as a single BAM. The tumor BAMs are staged as a directory and consumed by the pipeline's built-in `xam_ingress` sub-workflow without an intermediate merge step. The POC produces somatic variant calls, per-task performance metrics, a timeline visualization, and a cost extrapolation model for scaling to 150 tumor/normal pairs. Design and execution artifacts leverage the AWS HealthOmics MCP power (workflow packaging, container registry mapping, run monitoring, performance analysis, timeline generation).

## Glossary

- **AHO_Workflow**: The AWS HealthOmics private workflow resource that wraps the `wf-somatic-variation` pipeline definition, engine type `NEXTFLOW`, and parameter template.
- **AHO_Run**: A single execution of the `AHO_Workflow` against one tumor/normal input pair.
- **Run_Group**: The AWS HealthOmics run group resource that groups runs and applies safety caps (maximum duration, maximum concurrent runs). Runs attached to the group inherit its caps.
- **Pipeline_Version**: The exact upstream Git tag `v1.5.1` of the `epi2me-labs/wf-somatic-variation` repository. Any reference to the pipeline source, container image list, or `nextflow_schema.json` MUST resolve to this tag.
- **Tumor_Input_Directory**: An S3 prefix (referred to as `tumor_bams/`) containing two BAM files representing the ~60x COLO829 tumor sample as two ~30x sub-alignments.
- **Normal_Input_Directory**: An S3 prefix (referred to as `normal_bams/`) containing one BAM file representing the ~30x COLO829BL matched normal sample.
- **Read_Group_Sample_Tag**: The `SM:` field within a BAM file's `@RG` header line, used by `xam_ingress` to determine sample identity when combining multiple BAM inputs.
- **Basecaller_Config**: The ONT basecalling model identifier `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`, passed to the pipeline via `--override_basecaller_cfg`.
- **Container_Registry_Map**: A HealthOmics container registry map that redirects public container image pulls (Docker Hub, quay.io, ECR Public) referenced by `wf-somatic-variation` v1.5.1 to private ECR pull-through cache repositories.
- **Parameter_Template**: The JSON document that defines the pipeline parameters exposed to `AHO_Run` invocations, derived from the v1.5.1 `nextflow_schema.json`.
- **Compatibility_Check**: A pre-staging validation step that verifies both tumor BAMs share a single `Read_Group_Sample_Tag` value and originate from the same `Basecaller_Config`.
- **Pre_Merge_Fallback**: An off-HealthOmics preparation step using `samtools merge` and/or `samtools reheader`, executed only when `Compatibility_Check` fails, to produce a single merged tumor BAM before staging.
- **Performance_Report**: The structured output of the `AnalyzeAHORunPerformance` tool, containing per-task CPU, memory, and cost utilization metrics.
- **Timeline_Visualization**: The Gantt-style SVG produced by the `GenerateAHORunTimeline` tool showing per-task execution phases.
- **Cost_Extrapolation_Model**: A calculation that projects the per-pair cost observed in the POC run to a batch of 150 tumor/normal pairs.

## Requirements

### Requirement 1: Pipeline Version Pinning

**User Story:** As a bioinformatics engineer, I want the pipeline to be pinned to `v1.5.1`, so that POC results are reproducible and match the customer's on-prem baseline exactly.

#### Acceptance Criteria

1. WHEN the `AHO_Workflow` is created, THE AHO_Workflow SHALL reference the `epi2me-labs/wf-somatic-variation` source at Git tag `v1.5.1`.
2. WHEN the `Container_Registry_Map` is generated, THE Container_Registry_Map SHALL be derived from the container image list declared in `wf-somatic-variation` at tag `v1.5.1`.
3. WHEN the `Parameter_Template` is generated, THE Parameter_Template SHALL be derived from the `nextflow_schema.json` file at tag `v1.5.1`.
4. IF any pipeline artifact resolution step attempts to fetch a Git reference other than `v1.5.1` (including `master`, `main`, `latest`, or any other tag), THEN THE AHO_Workflow creation process SHALL abort with a version mismatch error.

### Requirement 2: Tumor Input Directory Ingestion

**User Story:** As a bioinformatics engineer, I want to stage two 30x tumor BAMs into a single directory and pass that directory to the pipeline, so that the pipeline's `xam_ingress` sub-workflow can combine them without a pre-merge step.

#### Acceptance Criteria

1. WHEN staging tumor inputs, THE Tumor_Input_Directory SHALL contain exactly two BAM files representing the two ~30x COLO829 sub-alignments.
2. WHEN the `AHO_Run` is started, THE `--bam_tumor` parameter SHALL be set to the S3 URI of the Tumor_Input_Directory, not to a single BAM file path.
3. THE POC design SHALL NOT include an AWS-side `samtools merge` step that combines the two tumor BAMs before the AHO_Run begins.
4. WHEN staging normal inputs, THE Normal_Input_Directory SHALL contain exactly one BAM file representing the ~30x COLO829BL sample.
5. WHEN the `AHO_Run` is started, THE `--bam_normal` parameter SHALL be set to the S3 URI of the Normal_Input_Directory.

### Requirement 3: Input Compatibility Validation

**User Story:** As a bioinformatics engineer, I want the two tumor BAMs to be verified for sample and basecaller consistency before staging, so that `xam_ingress` produces a coherent combined sample.

#### Acceptance Criteria

1. WHEN Compatibility_Check runs against the two tumor BAMs, THE Compatibility_Check SHALL extract the `Read_Group_Sample_Tag` from every `@RG` line in each BAM header.
2. WHEN Compatibility_Check runs against the two tumor BAMs, THE Compatibility_Check SHALL extract the basecaller model identifier from each BAM header.
3. WHERE both tumor BAMs contain the same single `Read_Group_Sample_Tag` value and the same `Basecaller_Config` value equal to `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`, THE Compatibility_Check SHALL emit a "pass" status and permit staging to proceed to the Tumor_Input_Directory.
4. IF the two tumor BAMs contain differing `Read_Group_Sample_Tag` values or differing basecaller model identifiers, THEN THE Compatibility_Check SHALL emit a "fail" status and record the specific mismatch fields in a diagnostic report.
5. WHEN Compatibility_Check runs against the normal BAM, THE Compatibility_Check SHALL verify the normal BAM's basecaller model identifier equals `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`.

### Requirement 4: Pre-Merge Fallback (Conditional)

**User Story:** As a bioinformatics engineer, I want an explicit fallback path to produce a single reheadered tumor BAM when compatibility validation fails, so that the POC can still run without silently corrupting sample identity.

#### Acceptance Criteria

1. IF Compatibility_Check emits a "fail" status, THEN THE Pre_Merge_Fallback SHALL be executed as an explicit prerequisite step outside the `AHO_Run`.
2. WHEN Pre_Merge_Fallback executes, THE Pre_Merge_Fallback SHALL produce a single merged tumor BAM whose `@RG` lines all carry a unified `Read_Group_Sample_Tag` value.
3. WHERE Pre_Merge_Fallback has produced a merged tumor BAM, THE Tumor_Input_Directory SHALL contain exactly one BAM file (the merged output) and THE `--bam_tumor` parameter SHALL still be set to the S3 URI of the Tumor_Input_Directory.
4. THE Pre_Merge_Fallback SHALL NOT be executed as part of the `AHO_Run`.

### Requirement 5: HealthOmics Workflow Creation and Container Mapping

**User Story:** As a bioinformatics engineer, I want the pipeline packaged as an AWS HealthOmics private workflow with all container images resolvable from private ECR, so that the run can execute in the isolated HealthOmics network environment.

#### Acceptance Criteria

1. WHEN the `AHO_Workflow` is created, THE AHO_Workflow SHALL be created in AWS region `ap-southeast-1`.
2. WHEN the `AHO_Workflow` is created, THE AHO_Workflow engine type SHALL be `NEXTFLOW`.
3. WHEN the `Container_Registry_Map` is generated, THE Container_Registry_Map SHALL redirect every public container image referenced by `wf-somatic-variation` v1.5.1 to a private ECR repository accessible to the HealthOmics service principal.
4. WHEN the `AHO_Workflow` is created, THE AHO_Workflow SHALL be associated with the generated Container_Registry_Map.
5. IF any container image referenced by `wf-somatic-variation` v1.5.1 lacks a corresponding entry in the Container_Registry_Map, THEN THE AHO_Workflow creation process SHALL abort with a missing container mapping error.
6. WHEN the `Parameter_Template` is generated, THE Parameter_Template SHALL include every parameter marked as required in the v1.5.1 `nextflow_schema.json`, plus `--bam_tumor`, `--bam_normal`, `--sample_name`, and `--override_basecaller_cfg`.

### Requirement 6: Run Execution and Storage

**User Story:** As a bioinformatics engineer, I want each AHO_Run to use dynamic storage and record its outputs to a predictable S3 location, so that POC operational overhead is minimized and outputs are easy to locate.

#### Acceptance Criteria

1. WHEN an `AHO_Run` is started, THE AHO_Run storage type SHALL be `DYNAMIC`.
2. WHEN an `AHO_Run` is started, THE AHO_Run SHALL be invoked with an IAM role ARN that permits reading the Tumor_Input_Directory and Normal_Input_Directory and writing to the run output S3 URI.
3. WHEN an `AHO_Run` is started, THE `--override_basecaller_cfg` parameter SHALL be set to `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`.
4. WHEN an `AHO_Run` completes with status `COMPLETED`, THE AHO_Run output S3 URI SHALL contain the somatic variant call outputs produced by `wf-somatic-variation` v1.5.1.
5. IF an `AHO_Run` completes with status `FAILED`, THEN THE run failure diagnosis SHALL be captured using `DiagnoseAHORunFailure` and stored alongside the run metadata.

### Requirement 7: Performance Measurement and Timeline

**User Story:** As a bioinformatics engineer, I want per-task performance metrics and a timeline visualization for every POC run, so that right-sizing decisions and bottleneck analysis are grounded in real measurements.

#### Acceptance Criteria

1. WHEN an `AHO_Run` reaches terminal status `COMPLETED` or `FAILED`, THE Performance_Report SHALL be generated by invoking `AnalyzeAHORunPerformance` against the run ID.
2. WHEN the Performance_Report is generated, THE Performance_Report SHALL include per-task CPU utilization, memory utilization, and cost figures.
3. WHEN an `AHO_Run` reaches terminal status `COMPLETED` or `FAILED`, THE Timeline_Visualization SHALL be generated by invoking `GenerateAHORunTimeline` against the run ID.
4. WHEN the Timeline_Visualization is generated, THE Timeline_Visualization SHALL be written to an S3 URI within the POC output bucket.

### Requirement 8: Right-Sizing Recommendations

**User Story:** As a bioinformatics engineer, I want the Performance_Report to drive concrete right-sizing recommendations, so that subsequent runs use the smallest instance sizes that still satisfy peak resource demand.

#### Acceptance Criteria

1. WHEN the Performance_Report is generated with a non-zero headroom, THE right-sizing recommendation SHALL identify, for each task, the smallest HealthOmics-supported instance size whose CPU and memory capacity is greater than or equal to the task's observed peak CPU and memory usage plus the specified headroom.
2. WHEN a right-sizing recommendation differs from the container's declared `cpu` and `memory` directives in `wf-somatic-variation` v1.5.1, THE right-sizing recommendation SHALL record the delta between observed peak usage and declared resources.

### Requirement 9: Cost Extrapolation

**User Story:** As a project stakeholder, I want the per-pair cost measured in the POC run to be projected to a batch of 150 tumor/normal pairs, so that budget planning for a full production run is grounded in observed pricing.

#### Acceptance Criteria

1. WHEN the Performance_Report contains a per-run total cost value, THE Cost_Extrapolation_Model SHALL compute the total cost of processing 150 tumor/normal pairs as the per-run total cost multiplied by 150.
2. WHEN the Cost_Extrapolation_Model is computed, THE Cost_Extrapolation_Model SHALL record the per-run total cost, the assumed pair count (150), the assumed storage type (`DYNAMIC`), and the region (`ap-southeast-1`).
3. WHERE right-sizing recommendations from Requirement 8 have been applied, THE Cost_Extrapolation_Model SHALL provide a second projection based on the right-sized per-run cost estimate.

### Requirement 10: Region Constraint

**User Story:** As a compliance-conscious engineer, I want all POC resources to reside in the Singapore region, so that data residency expectations for the POC are satisfied.

#### Acceptance Criteria

1. THE Tumor_Input_Directory SHALL reside in an S3 bucket located in AWS region `ap-southeast-1`.
2. THE Normal_Input_Directory SHALL reside in an S3 bucket located in AWS region `ap-southeast-1`.
3. THE AHO_Workflow SHALL be created in AWS region `ap-southeast-1`.
4. THE AHO_Run output S3 URI SHALL reference an S3 bucket located in AWS region `ap-southeast-1`.
5. THE ECR repositories referenced by the Container_Registry_Map SHALL reside in AWS region `ap-southeast-1`.
### Requirement 11: Run Duration Safety Cap

**User Story:** As a project stakeholder controlling cloud spend, I want a hard wall-clock cap on any POC run, so that a hung or stuck task cannot burn compute indefinitely without human intervention.

#### Acceptance Criteria

1. WHEN an `AHO_Run` is submitted, THE AHO_Run SHALL be associated with a `Run_Group` whose `maxDuration` value is exactly `4320` minutes (72 hours).
2. THE `Run_Group` referenced by the `AHO_Run` SHALL reside in AWS region `ap-southeast-1`.
3. IF the wall-clock duration of an `AHO_Run` exceeds the `maxDuration` value of its associated `Run_Group`, THEN THE AWS HealthOmics service SHALL cancel the AHO_Run and transition it to terminal status `CANCELLED`.
4. THE `Run_Group` SHALL configure `maxRuns` to `1`.
5. IF the `AHO_Run` is submitted without a `run_group_id`, THEN THE run submission process SHALL abort before invoking `StartAHORun`.
