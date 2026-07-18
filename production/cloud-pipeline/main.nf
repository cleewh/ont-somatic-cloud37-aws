#!/usr/bin/env nextflow
import groovy.json.JsonBuilder
nextflow.enable.dsl = 2

// Load base modules
include {
    prepare_reference
    } from './lib/reference.nf'
include {
    ingress as ingress_normal;
    ingress as ingress_tumor;
    ingress as ingress_tumor2;
    ingress_merged;
    ingress_merged as ingress_ubam_t1;
    ingress_merged as ingress_ubam_t2;
    ingress_merged as ingress_ubam_normal
    } from './lib/_ingress.nf'
include {
    somatic_sv as sv
    } from './workflows/wf-somatic-sv.nf'
include {
    getAllChromosomesBed;
    getVersions;
    getVersions_somvar;
    getParams;
    getGenome;
    report
    } from './modules/local/common'
include { igv } from './lib/igv.nf'
include {
    lookup_clair3_model;
    lookup_clair3_model as lookup_clairS_model;
    publish_snv
} from './modules/local/wf-somatic-snv'
include {
    alignment_stats; get_coverage; get_region_coverage; 
    publish_qc; get_shared_region
} from './workflows/bamstats.nf'
include {snv} from './workflows/wf-somatic-snv'
include {snv as snv_to} from './workflows/wf-somatic-snv-to'
include {mod} from './workflows/mod.nf'
include { detect_basecall_model } from './lib/model.nf'


// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process publish {    // publish inputs to output directory
    publishDir (
        params.out_dir,
        mode: "copy",
        saveAs: { dirname ? "$dirname/$fname" : fname }
    )
    input:
        tuple path(fname), val(dirname)
    output:
        path fname
    """
    """
}



// ---------------------------------------------------------------------------
// CLOUD ADAPTATION (nextflow-poc-on-aws): merge two tumor BAMs into one.
// On AWS HealthOmics each parameter stages as a single file, so the two ~30x
// tumor BAMs cannot be passed as a directory (as on-prem). When `bam_tumor2`
// is provided, this process merges the two coordinate-sorted tumor BAMs into a
// single sorted, re-headered BAM that the existing ingress_tumor path consumes.
// When `bam_tumor2` is null the workflow behaves exactly as upstream (on-prem).
// Uses the wf_common container (samtools already present).
// ---------------------------------------------------------------------------
process merge_tumor {
    label "wf_common"
    // cloud25: back to 16 CPU. cloud24c at 8 CPU took 102min vs ~90min at 16 CPU;
    // merge is on the critical path so the ~13min saving is worth ~$0.7.
    cpus 16
    memory { 16.GB * task.attempt }
    maxRetries 1
    errorStrategy { task.exitStatus in [137,140] ? 'retry' : 'finish' }
    // CLOUD FORK: by default the merged tumor BAM is a transient intermediate
    // (consumed by ingress_merged, then discarded with the run). Set
    // --save_merged_tumor true to persist it to the output bucket for reuse
    // (adds a ~290GB copy + storage cost). Default false = deleted.
    publishDir "${params.out_dir}/${sample}/merged_tumor", mode: 'copy', pattern: "merged_tumor.bam*", enabled: params.save_merged_tumor
    // cloud34: the two tumor uBAMs are realigned by minimap2 which names BOTH
    // outputs ${meta.alias}.bam == COLO829.bam (alias = params.sample_name). Staging
    // two identically-named files into one process is a fatal Nextflow collision
    // (killed cloud33). stageAs gives each a distinct staged name; samtools merge
    // reads them via ${t1}/${t2} regardless.
    input:
        tuple path(t1, stageAs: 'tumor1_aligned.bam'), path(t2, stageAs: 'tumor2_aligned.bam'), val(sample)
    output:
        tuple path("merged_tumor.bam"), path("merged_tumor.bam.bai"), emit: merged
    script:
    """
    # cloud31 align-then-merge: inputs are ALIGNED, sorted tumor BAMs (each tumor uBAM
    # was aligned in parallel by its own ingress/minimap2 upstream). Merge the two
    # aligned BAMs into one sorted, indexed tumor BAM (combined header keeps both @RG).
    samtools merge -@ ${task.cpus} -f -c -p merged_tumor.bam ${t1} ${t2}
    # Fix SM tag. Try IN-PLACE reheader (no rewrite of the ~290GB file); this
    # succeeds when the new header is not longer than the old (SM->${sample} is
    # short, so it normally is). Fall back to a full rewrite only if in-place fails.
    samtools view -H merged_tumor.bam | sed 's/\\tSM:[^\\t]*/\\tSM:${sample}/' > hdr.sam
    if samtools reheader -i hdr.sam merged_tumor.bam 2>/dev/null; then
        echo "[merge_tumor] reheader in-place OK (no rewrite)"
    else
        echo "[merge_tumor] in-place reheader not possible; rewriting header"
        samtools reheader hdr.sam merged_tumor.bam > merged_fixed.bam
        mv merged_fixed.bam merged_tumor.bam
    fi
    samtools quickcheck merged_tumor.bam
    samtools index -@ ${task.cpus} merged_tumor.bam
    """
}

// ---------------------------------------------------------------------------
// CLOUD FORK (cloud35): persist the ALIGNED tumor + normal BAMs to durable S3 so a
// future run can skip the (~$22) uBAM alignment and resume from aligned BAMs.
// Leaf process: hardlink-renames each input to a clean resume-friendly name
// (tumor_aligned.bam / normal_aligned.bam) then publishDir copies it (+ index) to
// <out_dir>/aligned_bams/. The hardlink is instant (same FS); the only real cost is
// the one-time S3 copy. Gated by --save_aligned_bams.
// ---------------------------------------------------------------------------
process publish_aligned {
    label "wf_common"
    cpus 2
    memory 4.GB
    publishDir "${params.out_dir}/aligned_bams", mode: 'copy', pattern: "*.bam*"
    input:
        tuple val(outname), path(bam, stageAs: 'input.bam'), path(bai, stageAs: 'input.bam.bai')
    output:
        tuple path("${outname}.bam"), path("${outname}.bam.bai")
    script:
    """
    ln input.bam ${outname}.bam 2>/dev/null || cp -L input.bam ${outname}.bam
    ln input.bam.bai ${outname}.bam.bai 2>/dev/null || cp -L input.bam.bai ${outname}.bam.bai
    samtools quickcheck ${outname}.bam
    """
}

// entrypoint workflow
WorkflowMain.initialise(workflow, params, log)
workflow {

    Map colors = NfcoreTemplate.logColours(params.monochrome_logs)

    def run_tumor_only = !params.bam_normal
    can_start = true
    // Check that bam_tumor and bam_normal files exist
    // because the check in ingress sometimes doesn't
    // show the error
    if (!file(params.bam_tumor).exists()) {
        log.error (colors.red + "Input path ${params.bam_tumor} does not exist" + colors.reset)
        can_start = false
    }    
    if (params.containsKey('bam_tumor2') && params.bam_tumor2 && !file(params.bam_tumor2).exists()) {
        log.error (colors.red + "Input path ${params.bam_tumor2} does not exist" + colors.reset)
        can_start = false
    }
    if (params.bam_normal && !file(params.bam_normal).exists()){
        log.error (colors.red + "Input path ${params.bam_normal} does not exist" + colors.reset)
        can_start = false
    }
    if (run_tumor_only && params.snv && params.liquid_tumor) {
        log.warn "The SNV tumor-only mode currently has no specific presets for liquid tumors."
    }
    if (!params.germline) {
        log.warn ("The workflow is running in somatic-only mode, germline calling will be skipped")
    }
    if (params.normal_vcf) {
        if (!file("${params.normal_vcf}", checkifExists: true)){
            throw new Exception("--normal_vcf is specified, but the file doesn't exist: ${params.normal_vcf}")
        }
        if (params.normal_vcf.endsWith('.gz') && !file("${params.normal_vcf}.tbi", checkifExists: true)){
            throw new Exception("No TBI index for VCF file: ${params.normal_vcf}")
        }
        log.info ("Pre-computed VCF for the normal sample provided; running germline calling only for tumor sample")
    }
    if (params.snv && params.hybrid_mode_vcf && params.genotyping_mode_vcf){
        throw new Exception("Can run --hybrid_mode_vcf or --genotyping_mode_vcf, not both. Choose one and try again.")
    }

    reference = prepare_reference([
        "input_ref": params.ref,
        "output_cache": true,
        "output_mmi": false
    ])
    ref = reference.ref
    ref_index = reference.ref_idx
    ref_cache = reference.ref_cache
    ref_gzindex = reference.ref_gzidx

    // canonical ref and BAM channels to pass around to all processes
    ref_channel = ref
    | concat(ref_index)
    | concat(ref_cache)
    | flatten
    | buffer(size: 4)


    // ************************************************************************
    // Bail from the workflow for a reason we should have already specified
    if (!can_start){
        throw new Exception("The workflow could not be started.")
    }
    // ************************************************************************

    // Dummy optional file
    OPTIONAL = file("$projectDir/data/OPTIONAL_FILE")

    // Programmatically define chromosome codes.
    // note that we avoid interpolation (eg. "${chr}N") to ensure that values
    // are Strings and not GStringImpl, ensuring that .contains works.
    ArrayList chromosome_codes = []
    ArrayList chromosomes = [1..22] + ["X", "Y", "M", "MT"]
    for (N in chromosomes.flatten()){
        chromosome_codes += ["chr" + N, "" + N]
    }

    Pinguscript.ping_start(nextflow, workflow, params)

    // Get software versions
    versions = getVersions() | getVersions_somvar
    parameters = getParams()

    /*
    * Start processing the bam files
    * It accepts two bam files: 
    * 1. Tumor bam
    * 2. Control bam (optional for mod)
    */
    // If running in tumor-only mode, create an empty channel.
    // CLOUD FORK (cloud32): uBAM ALIGNMENT-INCLUSIVE path. Inputs are UNALIGNED BAMs
    // (SQ=0). The stock ingress (xam_ingress -> get_valid_inputs) probes
    // file("${bam}.bai").exists(); on HealthOmics that registers a phantom S3 index
    // for import and FAILS the run (INPUT_URI_NOT_FOUND) because uBAMs have no .bai.
    // Instead we feed each uBAM straight into ingress_merged, which bypasses
    // xam_ingress and runs check_for_alignment + minimap2_alignment (neither reads the
    // index). Each uBAM is paired with the shipped 0-byte sentinel
    // data/OPTIONAL_FILE.bam.bai (a bundled workflow file, NOT an S3 import) as a
    // stand-in index; minimap2 regenerates the real index on its aligned output.
    // Each ingress_merged instance spawns INDEPENDENT minimap2 tasks that Nextflow
    // schedules IN PARALLEL (tumor1 || tumor2 || normal = 3-way; single tumor = 2-way).
    // Only after both tumor BAMs are ALIGNED+sorted does merge_tumor combine them.
    UBAM_IDX = file("$projectDir/data/OPTIONAL_FILE.bam.bai")
    if (params.bam_normal){
        bam_normal = ingress_ubam_normal(
                ref,
                ref_index,
                Channel.of( file(params.bam_normal) ).map{ b -> [ b, UBAM_IDX ] },
                params.sv ? Channel.of(['bam', 'bai']) : Channel.of(['cram', 'crai'])
            )
    } else {
        bam_normal = Channel.empty()
    }

    // Import the tumor, which is always required.
    if ( params.containsKey('bam_tumor2') && params.bam_tumor2 ) {
        tumor1_ch = ingress_ubam_t1(  ref, ref_index,
                        Channel.of( file(params.bam_tumor) ).map{ b -> [ b, UBAM_IDX ] },
                        params.sv ? Channel.of(['bam', 'bai']) : Channel.of(['cram', 'crai']) )
        tumor2_ch = ingress_ubam_t2( ref, ref_index,
                        Channel.of( file(params.bam_tumor2) ).map{ b -> [ b, UBAM_IDX ] },
                        params.sv ? Channel.of(['bam', 'bai']) : Channel.of(['cram', 'crai']) )
        // Pair the two ALIGNED tumor BAMs and merge them into one (aligned merge+index).
        merge_in = tumor1_ch.map{ xam, xai, meta -> [ xam, xai ] }
            .combine( tumor2_ch.map{ xam, xai, meta -> [ xam, xai ] } )
            .map{ t1x, t1i, t2x, t2i -> tuple( t1x, t2x, params.sample_name ) }
        merged_tumor_ch = merge_tumor( merge_in ).merged
        // Wrap the merged (aligned, sorted, indexed) BAM into the canonical
        // (xam, xai, meta) bam_channel. Construct the meta INLINE (mirrors the
        // ingress_merged meta). Merged tumor is aligned, so is_unaligned=false /
        // has_mapped_reads=true / to_align=false.
        bam_tumor = merged_tumor_ch.map{ mbam, mbai ->
            [ mbam, mbai, [alias: params.sample_name, barcode: null, type: 'test_sample',
              run_ids: [], basecall_models: [], is_cram: mbam.name.endsWith('.cram'),
              is_unaligned: false, has_mapped_reads: true, to_align: false] ]
        }
    } else {
        bam_tumor = ingress_ubam_t1( ref, ref_index,
                        Channel.of( file(params.bam_tumor) ).map{ b -> [ b, UBAM_IDX ] },
                        params.sv ? Channel.of(['bam', 'bai']) : Channel.of(['cram', 'crai']) )
    }

    // CLOUD FORK (cloud35): persist the ALIGNED tumor (merged) + normal BAMs so a
    // future run can resume from aligned BAMs and skip uBAM alignment. Publishes
    // tumor_aligned.bam(.bai) + normal_aligned.bam(.bai) to <out_dir>/aligned_bams/.
    // Fan-out of bam_tumor/bam_normal here is safe (DSL2 multi-consumer; these
    // channels are also consumed by all_bams below).
    if ( params.save_aligned_bams ) {
        publish_aligned(
            bam_tumor.map{ xam, xai, meta -> tuple('tumor_aligned', xam, xai) }
                .mix( bam_normal.map{ xam, xai, meta -> tuple('normal_aligned', xam, xai) } )
        )
    }

    // Combine everything
    all_bams = bam_normal
                .map{
                    xam, xai, meta -> 
                    [xam, xai, meta + [sample: params.sample_name, type: 'normal']]
                }
                .mix(
                    bam_tumor.map{
                        xam, xai, meta -> 
                        [xam, xai, meta + [sample: params.sample_name, type: 'tumor']]
                        }
                    )

    // Add genome build information
    // CW-2491: make this optional, allowing any genome to be processed
    // CW-3830: perform this before the QC as changing the metadata causes the
    //          `-resume` to break.
    if (params.annotation){
        getGenome(all_bams)
        getGenome.out.genome_build.map{
                bam, bai, meta, g_build -> 
                    [bam, bai, meta + [genome_build: g_build]]
            }.set{all_bams}
    } else {
        all_bams
            .map{
                bam, bai, meta ->
                [bam, bai, meta + [genome_build: null]]
            }
            .set{all_bams}
    }

    // Check input region bed file.
    // If it doesn't exists, then extract the regions from
    // the reference faidx file.
    bed = null
    default_bed_set = false
    if(params.bed){
        bed = Channel.fromPath(params.bed, checkIfExists: true)
    }
    else {
        default_bed_set = true
        bed = getAllChromosomesBed(ref_channel).all_chromosomes_bed
    }

    //Compute QC metrics and output QC statistics
    qcdata = alignment_stats(all_bams, ref_channel, bed, versions, parameters)
    qc_outputs = qcdata.outputs

    // populate output json with ingressed runids
    ArrayList ingressed_run_ids = []
    qcdata.runids.splitText().subscribe(
        onNext: {
            ingressed_run_ids += it.strip()
        },
        onComplete: {
            params.wf["ingress.run_ids"] = ingressed_run_ids
        }
    )

    // Apply bam coverage hard threshold to the pair
    // The dataset will fail if at least one of the bam has
    // coverage below the specified values. To account for different 
    // sequencing design, the two coverages are specified 
    // independently.
    if (params.tumor_min_coverage > 0 || (params.bam_normal && params.normal_min_coverage > 0)){
        // Define if a dataset passes or not the filtering
        if (params.bed){
            // Filter out the data based on the individual region's coverage
            coverage_check = qcdata.mosdepth_tuple.combine(bed) | get_region_coverage
            // Unlike humvar, the paired nature of the wf requires to branch and 
            // match the input bed files to detect the shared regions between T/N
            // first we separate tumor and normal
            coverage_check.filt_bed.branch{
                tumor: it[0].type == 'tumor'
                normal: it[0].type == 'normal'
            }.set{branched_filtered_beds}

            // Then, we cross T/N based on the sample name
            if (run_tumor_only){
                // If no normal BAM is provided, use the tumor outputs only.
                filt_bed = branched_filtered_beds.tumor
                    .map{
                        meta, bed -> [meta.sample, bed]
                    }
                bed = branched_filtered_beds.tumor
                    .map{
                        meta, bed -> bed
                    }
            } else {
                branched_filtered_beds.tumor
                    .map{
                        meta, bed -> [meta.sample, bed]
                    }.combine(
                        branched_filtered_beds.normal.map{
                            meta, bed -> [meta.sample, bed]
                        }, by: 0
                    ) | get_shared_region // and then process them to intersect the retained regions
                filt_bed = get_shared_region.out.bed_tuple
                // Prepare the filtered bed.
                bed = get_shared_region.out.bed_file
            }

            // Add more outputs
            qc_outputs
                .mix(
                    filt_bed.map{
                        sample, fname -> [fname, "${sample}/qc/coverage"]
                    }
                )
                .mix(
                    coverage_check.mosdepth_tuple.map{
                        meta, filt_cvg, dist, threshold -> [filt_cvg, "${meta.sample}/qc/coverage"]
                    }
                )
                .set{ qc_outputs }
        } else {
            // Define if a dataset passes or not the filtering
            coverage_check = get_coverage(qcdata.coverages)
        }


        // Branch filters on T/N class
        coverage_check.pass.branch{
            tumor: it[1].type == 'tumor'
            normal: it[1].type == 'normal'
        } .set { branched_checks }

        // Apply filters depending on the presence of normal or not
        if (run_tumor_only){
            // Apply filter
            branched_checks.tumor
                .branch{
                    sample, meta, pass, value ->
                    pass: pass == "true"
                    fail: true
                }
                .set{ depth_filtered }
            // Create temporary pass channel keeping only the sample name.
            tmp_pass_ch = depth_filtered.pass.map{ sample, meta, pass, value -> sample }
            // Define non-passing channel
            // Tumor-only is not a nested tuple, so avoid flatmapping
            fail_bam_channel = depth_filtered.fail
        } else {
            // Cross the values and apply filter.
            // Crossing creates a nested tuple of [ normal, tumor ], where
            // where normal is a tuple with structure:
            //   [
            //     sample ID,
            //     meta,
            //     boolean for whether the bam passes coverage check,
            //     coverage value
            //   ]
            // When branching, we therefore check the normal and the tumor
            // both pass the filtering threshold.
            branched_checks.normal
                .cross(branched_checks.tumor)
                .branch{
                    normal, tumor ->
                    pass: normal[2] == "true" && tumor[2] == "true"
                    fail: true
                }
                .set{ depth_filtered }
            // Create temporary pass channel keeping only the sample name.
            tmp_pass_ch = depth_filtered.pass.map{normal, tumor -> normal[0]}
            // Define non-passing channel
            // Being a nested tuple, we need to flatMap it first
            fail_bam_channel = depth_filtered.fail.flatMap()
        }
        // Add the bam and branch them based on passing/failing
        // the depth filter.
        tmp_pass_ch
            .combine(all_bams.map{it -> [it[2].sample] + it}, by:0)
            .map{ sample, xam, xai, meta -> [xam, xai, meta] }
            .set{ pass_bam_channel }

        // If it doesn't pass the minimum depth required, 
        // emit a bam channel of discarded bam files.
        // Log out an error of failed coverage.
        // The method is much more convoluted to print only the type that is 
        // failing, whether it is normal or tumor, and their respective thresholds.
        fail_bam_channel
            .map{
                sample, meta, passing, coverage ->
                def threshold = meta.type =='tumor' ? params.tumor_min_coverage as float : params.normal_min_coverage as float
                def logged = coverage as float < threshold ? 
                "will not be processed by the workflow as the detected coverage of ${coverage}x is below the minimum coverage threshold of ${threshold}x required for analysis" : 
                "will not be processed as the matching bam is below the minimum coverage threshold required for analysis"
                [sample, meta, coverage, threshold, logged]
            }
            .subscribe {
                log.error "ERROR: Sample ${it[0]} (${it[1].type}) ${it[4]}."
            }
    } else {
        // If the bam_min_depth is 0, then run regardless.
        all_bams.set{ pass_bam_channel }
    }
    // Output QC data
    publish_qc( qc_outputs )

    // Create minimal channel for joint report
    for_joint_report = qcdata.report_qc

    // Run snv workflow if requested
    if (params.snv) {
        // Use the new wf-human-variation library to define basecaller model.
        detect_basecall_model(pass_bam_channel, qcdata.basecallers)
        basecaller_cfg = detect_basecall_model.out.basecaller_cfg
        pass_bam_channel = detect_basecall_model.out.bam_channel

        // Get Clair3 model
        clair3_model = lookup_clair3_model(
            Channel.fromPath("${projectDir}/data/clair3_models.tsv", checkIfExists: true),
            basecaller_cfg,
            "Clair3",
            false
        )
        
        if (run_tumor_only){
            clairS_model = lookup_clairS_model(
                Channel.fromPath("${projectDir}/data/clairs_models_to.tsv", checkIfExists: true),
                basecaller_cfg,
                "ClairS_TO",
                false
            )
            clair_vcf = snv_to(
                pass_bam_channel,
                bed,
                ref_channel,
                clairS_model,
                clair3_model
            )
        } else {
            clairS_model = lookup_clairS_model(
                Channel.fromPath("${projectDir}/data/clairs_models.tsv", checkIfExists: true),
                basecaller_cfg,
                "ClairS",
                params.liquid_tumor
            )
            clair_vcf = snv(
                pass_bam_channel,
                bed,
                ref_channel,
                clairS_model,
                clair3_model
            )
        }
        
        // Publish outputs in the appropriate folder
        clair_vcf.outputs | publish_snv
        snv_joint_report = clair_vcf.report_snv
        snv_vcf = clair_vcf.vcf_ch
    } else {
        snv_joint_report = Channel.empty()
        snv_vcf = Channel.empty()
    }
    
    // Start SV calling workflow
    if (params.sv){
        sv_result = sv(pass_bam_channel, ref_channel, OPTIONAL)
        sv_joint_report = sv_result.report_sv
        sv_vcf = sv_result.sv_vcf
    } else {
        sv_joint_report = Channel.empty()
        sv_vcf = Channel.empty()
    }

    // Extract modified bases
    if (params.mod){
        modkit_output = mod(
            pass_bam_channel,
            ref_channel,
            chromosome_codes
        )
        mod_joint_report = modkit_output.report_mod
    } else {
        mod_joint_report = Channel.empty()
    }

    // Collect all the reports
    for_joint_report
        | mix(snv_joint_report)
        | mix(sv_joint_report)
        | mix(mod_joint_report)
        // Extract the alias as the combining key,
        // as the meta can change throughout the wfs.
        | map{
            meta, report -> [meta.alias, report]
        }
        // Remove the null values for the missing reports
        // Create a nested tuple with all the reports in it
        | groupTuple(by:0)
        // Add additional data types
        | combine(versions)
        | combine(parameters)
        | report

    // Add BAM to output if it has been realigned
    artifacts_ch = all_bams
        // Create the candidate output files to begin with. Given that ingress renames all files
        // to `read.bam`, we need to manually place them in different dirs.
        | map { xam, xai, meta -> [ [xam, xai], "${meta.alias}/bam/${meta.type}", meta ] }
        // Transpose to have a single file per tuple
        | transpose
        // Emit only BAMs that are processed by the wf (`src_xam` is set to null).
        | filter( { it[2].to_align || !it[2].src_xam } )
        // Drop the metadata; avoid literals to allow for empty channels
        | map{ it[0..1] }
        | concat(
            versions | map { fname -> [fname, null] },
            parameters | map { fname -> [fname, null] },
            report.out | map { fname -> [fname, null] }
        )

    // Create IGV configuration
    // To avoid saving the reference as an output (we just recently removed it),
    // We instead pass it as a string of params.ref. Given the following assumptions:
    // 1. the igv.json is only relevant in the desktop app, and
    // 2. the desktop app only passes absolute paths
    // The IGV configuration should work even when passing the input variable as file name.
    if (params.igv){
        // Prepare appropriate BAM files for IGV
        // The workflow can have the following scenarios:
        // 1. input BAMs > use absolute paths
        // 2. re-aligned input BAMs > use emitted aligned BAMs
        
        // Define output files
        igv_out = ref_channel
            // Add gzipped reference indexes
            | combine(ref_gzindex | ifEmpty([null, null, null]))
            | map {
                fasta, fai, cache, path_env, gzref, gzfai, gzi ->
                if (gzref){
                    [gzref, gzfai, gzi]
                } else {
                    [fasta, fai]
                }
            }
            | mix(
                snv_vcf | map { meta, vcf, tbi -> [vcf, tbi] },
                sv_vcf | map { meta, vcf, tbi -> [vcf, tbi] },
            )
            | igv
    }

    // Emit final set of outputs.
    artifacts_ch | publish
}

workflow.onComplete {
    Pinguscript.ping_complete(nextflow, workflow, params)
}
workflow.onError {
    Pinguscript.ping_error(nextflow, workflow, params)
}
