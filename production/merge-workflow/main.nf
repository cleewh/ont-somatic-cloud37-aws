#!/usr/bin/env nextflow
/*
 * tumor-bam-merge  --  minimal AWS HealthOmics pre-step workflow
 * ---------------------------------------------------------------------------
 * Merges a sample's two tumor BAMs into a single coordinate-sorted, indexed
 * BAM (as wf-somatic-variation v1.5.1 requires a single bam_tumor file) and
 * passes the normal BAM through. Runs ENTIRELY inside AWS HealthOmics - no EC2.
 *
 * Chain per pair:  [this merge run]  ->  [wf-somatic-variation run]
 *
 * Params (via HealthOmics parameter template):
 *   sample_name  sample/alias; becomes the unified @RG SM tag
 *   tumor1       S3 URI of tumor BAM 1  (HealthOmics stages as a local file)
 *   tumor2       S3 URI of tumor BAM 2
 *   normal       S3 URI of the normal BAM
 *
 * Outputs (published to the run output URI):
 *   merged_tumor.bam(+.bai)   -> feed to wf-somatic-variation --bam_tumor
 *   normal.bam(+.bai)         -> feed to wf-somatic-variation --bam_normal
 */
nextflow.enable.dsl = 2

params.sample_name = "SAMPLE"
params.tumor1      = null
params.tumor2      = null
params.normal      = null
params.merge_threads = 8

process merge_tumor {
    // Sort-preserving merge of two coordinate-sorted tumor BAMs, unify the SM
    // tag, index, and integrity-check. `samtools merge` (NOT cat) so the output
    // stays globally sorted and indexable.
    cpus 8
    memory { 16.GB * task.attempt }
    maxRetries 1
    errorStrategy { task.exitStatus in [137,140] ? 'retry' : 'finish' }
    publishDir "${params.out_dir}", mode: 'copy'

    input:
        tuple val(sample), path(t1), path(t2)
    output:
        tuple path("merged_tumor.bam"), path("merged_tumor.bam.bai")
    script:
    """
    samtools merge -@ ${task.cpus} -f -c -p merged_raw.bam ${t1} ${t2}
    samtools view -H merged_raw.bam | sed 's/\\tSM:[^\\t]*/\\tSM:${sample}/' > hdr.sam
    samtools reheader hdr.sam merged_raw.bam > merged_tumor.bam
    rm -f merged_raw.bam
    samtools index -@ ${task.cpus} merged_tumor.bam
    samtools quickcheck merged_tumor.bam
    """
}

process passthrough_normal {
    // Copy + (re)index the normal BAM so both inputs land in the run output
    // under predictable names. Kept as its own small task.
    cpus 4
    memory { 8.GB * task.attempt }
    publishDir "${params.out_dir}", mode: 'copy'

    input:
        path(n)
    output:
        tuple path("normal.bam"), path("normal.bam.bai")
    script:
    """
    cp ${n} normal.bam
    samtools index -@ ${task.cpus} normal.bam
    samtools quickcheck normal.bam
    """
}

workflow {
    if( !params.tumor1 || !params.tumor2 || !params.normal )
        error "tumor1, tumor2 and normal are all required"

    tumor_ch  = Channel.of( tuple(params.sample_name, file(params.tumor1), file(params.tumor2)) )
    normal_ch = Channel.of( file(params.normal) )

    merge_tumor(tumor_ch)
    passthrough_normal(normal_ch)
}
