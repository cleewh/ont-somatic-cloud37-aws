// Define memories for the phasing
def req_mem = params.use_longphase ? [7.GB, 31.GB, 56.GB] : [4.GB, 7.GB, 12.GB]

process make_chunks {
    // Do some preliminaries. Ordinarily this would setup a working directory
    // that all other commands would make use off, but all we need here are the
    // list of contigs and chunks.
    label "wf_somatic_snv"
    cpus 1
    memory 4.GB
    input:
        tuple val(meta), path(bam), path(bai), path(contigs), path(ref), path(fai), path(ref_cache), env(REF_PATH), path(bed), val(model)
        val clair3_mode
    output:
        tuple val(meta), path("clair_output_${meta.sample}_${meta.type}/tmp/CONTIGS"), emit: contigs_file
        tuple val(meta), path("clair_output_${meta.sample}_${meta.type}/tmp/CHUNK_LIST"), emit: chunks_file
        tuple val(meta), path("clair_output_${meta.sample}_${meta.type}/tmp/split_beds/"), emit: split_beds, optional: true
        tuple val(meta), path("clair_output/tmp/CMD"), emit: cmd_file

    script:
        def bedargs = params.bed ? "--bed_fn ${bed}" : ""
        def bedprnt = bed.name != 'OPTIONAL_FILE' ? "--bed_fn=${bed}" : ''
        // Define calling parameters to reflect ClairS behaviour
        // Default is Clair3 fast mode
        """
        # CW-2456: save command line to add to VCF file (very long command...)
        mkdir -p clair_output/tmp
        echo "run_clair3.sh --bam_fn=${bam} ${bedprnt} --ref_fn=${ref} --output=clair_output --platform=ont --sample_name=${params.sample_name} --model_path=\${CLAIR_MODELS_PATH}/clair3_models/${model}/ --ctg_name=${params.ctg_name} --chunk_num=0 --chunk_size=20000000 --qual=2 --var_pct_full=${params.clair3_var_pct_full} --ref_pct_full=${params.clair3_ref_pct_full} --snp_min_af=${clair3_mode.min_snps_af} --indel_min_af=${clair3_mode.min_indels_af} --min_contig_size=${params.min_contig_size}" > clair_output/tmp/CMD

        # CW-2456: prepare other inputs normally
        mkdir -p clair_output
        CTG_LIST=\$( tr '\\n' ',' < ${contigs} )
        echo "Running on contigs: \$CTG_LIST"
        python \$(which clair3.py) CheckEnvs ${bedargs} \\
            --bam_fn ${bam} \\
            --output_fn_prefix clair_output_${meta.sample}_${meta.type} \\
            --ref_fn ${ref} \\
            --vcf_fn ${params.vcf_fn} \\
            --ctg_name \$CTG_LIST \\
            --chunk_num 0 \\
            --chunk_size 20000000 \\
            --threads 1  \\
            --qual 2 \\
            --sampleName ${meta.sample} \\
            --var_pct_full ${params.clair3_var_pct_full} \\
            --ref_pct_full ${params.clair3_ref_pct_full} \\
            --snp_min_af ${clair3_mode.min_snps_af} \\
            --indel_min_af ${clair3_mode.min_indels_af} \\
            --min_contig_size ${params.min_contig_size} \\
            --cmd_fn clair_output/tmp/CMD
        """
}


process pileup_variants {
    // Calls variants per region ("chunk") using pileup network.
    label "wf_somatic_snv"
    cpus 1
    // This workflow takes 4Gb in, but on occasions (0.7% of jobs) there    
    // can be unexpected spikes of up to 8GB. Hard to predict the reason
    // for this, but the chances increase with larger genomes. Use retries.
    memory { 4.GB * task.attempt }
    errorStrategy 'retry'
    maxRetries 1
    input:
        tuple val(meta), 
            path(bam), 
            path(bai), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH), 
            path(bed),
            path(split_bed),
            val(region),
            val(model),
            path(command)
        val clair3_mode
    output:
        // TODO: make this explicit, why is pileup VCF optional?
        tuple val(meta), 
            path("pileup_${meta.sample}_${meta.type}_${region.contig}_${region.chunk_id}.vcf"), 
            optional: true, 
            emit: pileup_vcf_chunks
        tuple val(meta), path("gvcf_tmp_path/*"), optional: true, emit: pileup_gvcf_chunks
    shell:
        // note: the VCF output here is required to use the contig
        //       name since that's parsed in the SortVcf step
        // note: snp_min_af and indel_min_af have an impact on performance
        def bedargs = bed.name != 'OPTIONAL_FILE' ? "--bed_fn ${bed} --extend_bed split_bed/${region.contig}" : ''
        """
        python \$(which clair3.py) CallVariantsFromCffi \\
            --chkpnt_fn \${CLAIR_MODELS_PATH}/clair3_models/${model}/pileup \\
            --bam_fn ${bam} \\
            --call_fn pileup_${meta.sample}_${meta.type}_${region.contig}_${region.chunk_id}.vcf \\
            --ref_fn ${ref} \\
            --ctgName ${region.contig} \\
            --chunk_id ${region.chunk_id} \\
            --chunk_num ${region.total_chunks} \\
            --platform ont \\
            --fast_mode False \\
            --snp_min_af ${clair3_mode.min_snps_af} \\
            --indel_min_af ${clair3_mode.min_indels_af} \\
            --minMQ ${params.clair3_min_mq} \\
            --minCoverage ${clair3_mode.min_cvg} \\
            --base_err ${params.clair3_base_err} \\
            --gq_bin_size ${params.clair3_gq_bin_size} \\
            --call_snp_only False \\
            --sampleName ${meta.sample} \\
            --vcf_fn ${params.vcf_fn} \\
            --enable_long_indel False \\
            --samtools samtools \\
            --gvcf ${params.GVCF} \\
            --temp_file_dir gvcf_tmp_path \\
            --pileup \\
            --cmd_fn ${command} \\
            ${bedargs}
        """
}


process aggregate_pileup_variants {
    // Aggregates and sorts all variants (across all chunks of all contigs)
    // from pileup network. Determines quality filter for selecting variants
    // to use for phasing.
    label "wf_somatic_snv"
    cpus 2
    memory { 4.GB * task.attempt }
    maxRetries 2
    errorStrategy = {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta), 
            path(vcfs, stageAs: "input_vcfs/*"),
            path(ref), 
            path(fai), 
            path(ref_cache),
            env(REF_PATH),
            path(contigs_file),
            val(model),
            path(command)
    output:
        tuple val(meta), path("pileup_${meta.sample}_${meta.type}.vcf.gz"), path("pileup_${meta.sample}_${meta.type}.vcf.gz.tbi"), emit: pileup_vcf
        tuple val(meta), path("phase_qual"), emit: phase_qual
    script:
        def var_pct_phasing = "--var_pct_phasing 0.7"
        if (model == "r941_prom_sup_g5014" || model == "r941_prom_hac_g5014") {
            var_pct_phasing = "--var_pct_phasing 0.8"
        }
        """
        pypy \$(which clair3.py) SortVcf \
            --input_dir input_vcfs/ \
            --vcf_fn_prefix pileup_${meta.sample}_${meta.type} \
            --output_fn pileup_${meta.sample}_${meta.type}.vcf \
            --sampleName ${params.sample_name} \
            --ref_fn ${ref} \
            --contigs_fn ${contigs_file} \
            --cmd_fn ${command}

        # Replaced bgzip with the faster bcftools index -n
        if [ "\$( bcftools index --threads !{task.cpus} -n pileup_${meta.sample}_${meta.type}.vcf.gz )" -eq 0 ]; \
        then echo "[INFO] Exit in pileup variant calling"; exit 1; fi

        bgzip -@ ${task.cpus} -fdc pileup_${meta.sample}_${meta.type}.vcf.gz | \
            pypy \$(which clair3.py) SelectQual --phase ${var_pct_phasing} --output_fn .
        """
}


process select_het_snps {
    // Filters a VCF by contig, selecting only het SNPs.
    label "wf_somatic_snv"
    cpus 2
    memory 4.GB
    input:
        tuple val(meta), path(pileup_vcf), path(pileup_tbi), path(split, stageAs: "phase_qual"), val(contig)
        // this is used implicitely by the program
        // https://github.com/HKU-BAL/Clair3/blob/329d09b39c12b6d8d9097aeb1fe9ec740b9334f6/preprocess/SelectHetSnp.py#L29
        
    output:
        tuple path("split_folder_${meta.sample}_${meta.type}/${contig}.vcf.gz"), path("split_folder_${meta.sample}_${meta.type}/${contig}.vcf.gz.tbi"), val(meta), val(contig), emit: het_snps_vcf
    shell:
        '''
        mkdir -p split_folder_!{meta.sample}_!{meta.type}/
        cp phase_qual split_folder_!{meta.sample}_!{meta.type}/
        pypy $(which clair3.py) SelectHetSnp \
            --vcf_fn !{pileup_vcf} \
            --split_folder split_folder_!{meta.sample}_!{meta.type}/ \
            --ctgName !{contig}

        bgzip -c split_folder_!{meta.sample}_!{meta.type}/!{contig}.vcf > split_folder_!{meta.sample}_!{meta.type}/!{contig}.vcf.gz
        tabix split_folder_!{meta.sample}_!{meta.type}/!{contig}.vcf.gz
        '''
}


process phase_contig {
    // Tags reads in an input BAM from heterozygous SNPs
    // The haplotag step was removed in clair-v0.1.11 so this step re-emits
    //   the original BAM and BAI as phased_bam for compatability,
    //   but adds the VCF as it is now tagged with phasing information
    //   used later in the full-alignment model
    label "wf_somatic_snv"
    cpus 4
    // Define memory from phasing tool and number of attempt
    memory { req_mem[task.attempt - 1] }
    maxRetries 2
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta), 
            path(het_snps), 
            path(het_snps_tbi), 
            val(contig), 
            path(bam), 
            path(bai), 
            path(ref), 
            path(fai), 
            path(ref_cache),
            env(REF_PATH)
    output:
        tuple val(meta), val(contig), path(bam), path(bai), path("phased_${meta.sample}_${meta.type}_${contig}.vcf.gz"), path("phased_${meta.sample}_${meta.type}_${contig}.vcf.gz.tbi"), emit: phased_bam_and_vcf
    script:
        if (params.use_longphase_intermediate)
        """
        echo "Using longphase for phasing"
        # longphase needs decompressed 
        bgzip -@ ${task.cpus} -dc ${het_snps} > snps.vcf
        longphase phase --ont -o phased_${meta.sample}_${meta.type}_${contig} \
            -s snps.vcf -b ${bam} -r ${ref} -t ${task.cpus}
        bgzip phased_${meta.sample}_${meta.type}_${contig}.vcf
        tabix -f -p vcf phased_${meta.sample}_${meta.type}_${contig}.vcf.gz
        """
        else
        """
        echo "Using whatshap for phasing"
        whatshap phase \
            --output phased_${meta.sample}_${meta.type}_${contig}.vcf.gz \
            --reference ${ref} \
            --chromosome ${contig} \
            --distrust-genotypes \
            --ignore-read-groups \
            ${het_snps} \
            ${bam}
        tabix -f -p vcf phased_${meta.sample}_${meta.type}_${contig}.vcf.gz
        """
}


process get_qual_filter {
    // Determines quality filter for selecting candidate variants for second
    // stage "full alignment" calling.
    label "wf_somatic_snv"
    cpus 2
    memory 4.GB
    input:
        tuple val(meta), path("pileup.vcf.gz"), path("pileup.vcf.gz.tbi")
    output:
        tuple val(meta), path("output_${meta.sample}_${meta.type}/qual"), emit: full_qual
    shell:
        '''
        echo "[INFO] 5/7 Select candidates for full-alignment calling"
        mkdir -p output_!{meta.sample}_!{meta.type}
        bgzip -fdc pileup.vcf.gz | \
        pypy $(which clair3.py) SelectQual \
                --output_fn output_!{meta.sample}_!{meta.type} \
                --var_pct_full !{params.clair3_var_pct_full} \
                --ref_pct_full !{params.clair3_ref_pct_full} \
                --platform ont 
        '''
}


process create_candidates {
    // Create BED files for candidate variants for "full alignment" network
    // from the previous full "pileup" variants across all chunks of all chroms
    //
    // Performed per chromosome; output a list of bed files one for each chunk.
    label "wf_somatic_snv"
    cpus 2
    memory 4.GB
    input:
        tuple val(meta), 
            path("pileup.vcf.gz"), 
            path("pileup.vcf.gz.tbi"), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            path("qual"), 
            val(contig)
        // this is used implicitely by the program
        // https://github.com/HKU-BAL/Clair3/blob/329d09b39c12b6d8d9097aeb1fe9ec740b9334f6/preprocess/SelectCandidates.py#L146
    output:
        tuple val(meta), val(contig), path("candidate_bed_${meta.sample}_${meta.type}/${contig}.*"), emit: candidate_bed, optional: true
    shell:
        // This creates BED files as candidate_bed/<ctg>.0_14 with candidates
        // along with a file the FULL_ALN_FILE_<ctg> listing all of the BED
        // files.  All we really want are the BEDs, the file of filenames is
        // used for the purposes of parallel in the original workflow.
        // https://github.com/HKU-BAL/Clair3/blob/329d09b39c12b6d8d9097aeb1fe9ec740b9334f6/scripts/clair3.sh#L218

        // TODO: would be nice to control the number of BEDs produced to enable
        // better parallelism.
        '''
        mkdir -p candidate_bed_!{meta.sample}_!{meta.type}/
        cp qual candidate_bed_!{meta.sample}_!{meta.type}/
        pypy $(which clair3.py) SelectCandidates \
            --pileup_vcf_fn pileup.vcf.gz \
            --split_folder candidate_bed_!{meta.sample}_!{meta.type} \
            --ref_fn !{ref} \
            --var_pct_full !{params.clair3_var_pct_full} \
            --ref_pct_full !{params.clair3_ref_pct_full} \
            --platform ont \
            --ctgName !{contig}

        '''
}


process mosdepth_split_depth {
    // CLOUD FORK (cloud20): dedicated FINE-resolution depth track for the
    // depth-aware split. The QC mosdepth uses 50kb windows (depth_window_size)
    // which DILUTE sharp centromeric/satellite depth spikes: a ~3000x peak over
    // ~10kb inside a 50kb window averages to a few-hundred x, so those candidates
    // are ~10-20x under-weighted and the split UNDER-fragments the deepest loci
    // -> multi-hour evaluate_candidates stragglers on chr1/9/16-class regions.
    // A ~2kb window resolves those peaks so the mean-depth^2 weighting fragments
    // them correctly, while shallow regions are untouched (no extra shards).
    // Single mosdepth -x fast pass, tumor only, genome-wide; runs in parallel with
    // pileup/phasing so it adds ~0 to the critical path. No `label` -> inherits the
    // base wf-somatic-variation container (which provides the mosdepth binary,
    // same as the QC mosdepth process).
    cpus 4
    memory { 4.GB * task.attempt }
    maxRetries 2
    errorStrategy 'retry'
    input:
        tuple path(xam), path(xam_idx), val(meta)
    output:
        tuple val(meta.sample), path("${meta.sample}_split_depth.regions.bed.gz"), emit: depth
    script:
        """
        mosdepth -x -n -t ${task.cpus} --by ${params.split_depth_window_size} ${meta.sample}_split_depth ${xam}
        """
}


process split_candidates_by_depth {
    // CLOUD FORK (nextflow-poc-on-aws): depth-aware balancing of candidate BEDs.
    // full-alignment cost scales SUPER-linearly with local depth, so weight each
    // candidate by mean-depth^2 and cut a new contiguous sub-BED when cumulative
    // weight exceeds a budget. Deep loci -> many small shards; shallow loci ->
    // few large shards. Balanced runtimes, no straggler, contiguous (no scatter
    // penalty). Accuracy-preserving: identical candidates, only partitioned.
    //
    // cloud15: depth is read from the mosdepth 50kb-windowed track ALREADY
    // computed for the tumor in the alignment_stats QC stage (regions.bed.gz,
    // col4 = mean depth), joined to candidates in pure awk (two-pointer merge,
    // no bedtools/samtools dependency - wf_common has only gzip/sort/awk). This
    // replaces the previous `samtools bedcov` full BAM re-scan (multi-hour on
    // deep contigs, the pipeline's long pole) with a near-instant interval
    // overlap and NO BAM reads. 50kb resolution captures the megabase-scale deep
    // loci that drive the straggler; sub-window spikes contribute too few
    // candidates to matter.
    label "wf_common"
    cpus 2
    memory { 4.GB * task.attempt }
    input:
        tuple val(meta), val(contig), path(beds, stageAs: "cand/*"), path(depth_regions)
    output:
        tuple val(meta), val(contig), path("dsplit/*"), emit: beds, optional: true
        path("*.split_manifest.tsv"), emit: manifest, optional: true
    shell:
        '''
        mkdir -p dsplit
        cat cand/* > cand.bed 2>/dev/null || true
        if [ ! -s cand.bed ]; then exit 0; fi
        sort -k1,1 -k2,2n cand.bed > cand.sorted.bed
        gzip -dc !{depth_regions} | awk -v c='!{contig}' 'BEGIN{FS=OFS="\t"} $1==c' | sort -k1,1 -k2,2n > depth.contig.bed
        # Depth join in pure awk (no bedtools dependency): a two-pointer merge of
        # the sorted depth windows against the sorted candidates. Each candidate
        # gets the mean depth of the window(s) it overlaps. If no windows exist for
        # the contig (n==0), depth defaults to 1 (uniform split by count) - safe.
        #
        # cloud26: SELF-TUNING TIME-TARGETED split (replaces cloud25's fixed d^2
        # budget). Each candidate's weight = min(d, DSAT)^P with:
        #   P    = weight/cost exponent 2.5 (measured ClairS cost ~ depth^2.6)
        #   DSAT = saturation depth 73438x (per-candidate cost caps at ~60s there;
        #          weight must not grow past it or deep loci over-fragment)
        # A shard is cut when cumulative weight >= B OR count >= M, where the budget
        #   B = TMIN*60 / K
        # is derived IN-AWK from the target shard minutes (TMIN) and the calibrated
        # cost coefficient (K, seconds per unit Sum(min(d,DSAT)^P)). B is a constant
        # but the split is DYNAMIC PER SAMPLE: applied to each sample's own depth
        # track, a deeper/amplified sample yields more total weight -> more shards,
        # each still ~TMIN minutes. M (cap) stays a shallow-region backstop. A
        # per-contig manifest (candidates, total weight W, budget, shard count, and
        # the calibration constants) is emitted for audit/reproducibility.
        awk -v P=!{params.clairs_split_weight_exp} \
            -v DSAT=!{params.clairs_split_depth_saturation} \
            -v K=!{params.clairs_split_cost_k} \
            -v TMIN=!{params.clairs_target_shard_minutes} \
            -v M=!{params.clairs_max_candidates_per_shard} \
            -v C='!{contig}' '
        BEGIN { FS=OFS="\t"; B=TMIN*60.0/K; acc=0; cc=0; i=0; n=0; j=0; W=0; ncand=0 }
        FNR==NR { ws[++n]=$2+0; we[n]=$3+0; wd[n]=$4+0; next }
        {
            s=$2+0; e=$3+0
            while (j < n && we[j+1] <= s) j++
            sum=0; cnt=0; k=j+1
            while (k <= n && ws[k] < e) { if (we[k] > s) { sum+=wd[k]; cnt++ }; k++ }
            d = (cnt>0) ? sum/cnt : 1
            if (d < 1) d = 1
            dw = (d < DSAT) ? d : DSAT
            w = dw ^ P
            fn = sprintf("dsplit/%s.part.%05d.bed", C, i)
            print $0 >> fn
            acc += w; cc++; W += w; ncand++
            if (acc >= B || cc >= M) { close(fn); i++; acc=0; cc=0 }
        }
        END {
            ns = i + (cc>0 ? 1 : 0)
            print C, ncand, W, B, ns, P, DSAT, K, TMIN > (C ".split_manifest.tsv")
            # cloud29: echo to stdout (CloudWatch) for LIVE visibility. Plain print with
            # OFS (tab) - NOT printf - to avoid an awk "runaway string constant" the
            # multi-line printf format hit in cloud28. Grep SPLIT_MANIFEST in the log.
            print "SPLIT_MANIFEST", C, ncand, W, B, ns, P, DSAT, K, TMIN
        }' depth.contig.bed cand.sorted.bed
        '''
}

process evaluate_candidates {
    // Run "full alignment" network for variants in a candidate bed file.
    // phased_bam just references the input BAM as it no longer contains phase information.
    // This can go very high, depending on the depth of coverage and size of the dataset.
    label "wf_somatic_snv"
    cpus 1
    // CLOUD FORK: depth-aware shards over ultra-deep loci load deep read stacks
    // for full-alignment and can OOM at the base 8GB regardless of candidate
    // count. HealthOmics OOM does NOT always surface as exit 137/140, so the
    // old conditional retry never fired -> hard FAILED. Use plain 'retry' so any
    // failure (incl. OOM) retries with memory scaled 8->16->24->32GB. The many
    // shallow shards succeed on attempt 1 at 8GB; only the rare deep shard escalates.
    memory { 8.GB * task.attempt }
    maxRetries 4
    errorStrategy 'retry'
    input:
        tuple val(meta), val(contig), path(phased_bam), path(phased_bam_index), path(phased_vcf), path(phased_tbi), path(command)
        tuple val(meta_2), val(contig_2), path(candidate_bed)
        tuple path(ref), path(fai), path(ref_cache), env(REF_PATH)
        val model
        val clair3_mode
    output:
        tuple val(meta), path("output_${meta.sample}_${meta.type}/full_alignment_*.vcf"), emit: full_alignment, optional: true
    script:
        filename = candidate_bed.name
        // Define calling parameters to reflect ClairS behaviour
        """
        mkdir -p output_${meta.sample}_${meta.type}
        echo "[INFO] 6/7 Call low-quality variants using full-alignment model"
        python \$(which clair3.py) CallVariantsFromCffi \
            --chkpnt_fn \${CLAIR_MODELS_PATH}/clair3_models/${model}/full_alignment \
            --bam_fn ${phased_bam} \
            --call_fn output_${meta.sample}_${meta.type}/full_alignment_${filename}.vcf \
            --sampleName ${meta.sample} \
            --ref_fn ${ref} \
            --full_aln_regions ${candidate_bed} \
            --ctgName ${contig} \
            --add_indel_length \
            --minMQ ${params.clair3_min_mq} \
            --minCoverage ${clair3_mode.min_cvg} \
            --platform ont \
            --use_gpu False \
            --samtools samtools \
            --enable_long_indel False \
            --phased_vcf_fn ${phased_vcf} \
            --no_phasing_for_fa False \
            --vcf_fn ${params.vcf_fn} \
            --gvcf ${params.GVCF} \
            --cmd_fn ${command}
        """
}


process aggregate_full_align_variants {
    // Sort and merge all "full alignment" variants
    label "wf_somatic_snv"
    cpus 2
    memory { 4.GB * task.attempt }
    maxRetries 3
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta), 
            path(vcfs, stageAs: "full_alignment/*"), 
            path(gvcfs, stageAs: "gvcf_tmp_path/*"), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH), 
            path(contigs),
            path(command)
    output:
        tuple val(meta), path("full_alignment_${meta.sample}_${meta.type}.vcf.gz"), path("full_alignment_${meta.sample}_${meta.type}.vcf.gz.tbi"), emit: full_aln_vcf
        tuple val(meta), path("non_var.gvcf"), optional: true, emit: non_var_gvcf
    shell:
        '''
        pypy $(which clair3.py) SortVcf \
            --input_dir full_alignment \
            --output_fn full_alignment_!{meta.sample}_!{meta.type}.vcf \
            --sampleName !{meta.sample} \
            --ref_fn !{ref} \
            --cmd_fn !{command} \
            --contigs_fn !{contigs}


        if [ "$( bcftools index --threads !{task.cpus} -n full_alignment_!{meta.sample}_!{meta.type}.vcf.gz )" -eq 0 ]; then
            echo "[INFO] Exit in full-alignment variant calling"
            exit 0
        fi

        # TODO: this could be a separate process
        if [ "!{params.GVCF}" == "true" ]; then
            pypy $(which clair3.py) SortVcf \
                --input_dir gvcf_tmp_path \
                --vcf_fn_suffix .tmp.gvcf \
                --output_fn non_var.gvcf \
                --sampleName !{meta.sample} \
                --ref_fn !{ref} \
                --cmd_fn !{command} \
                --contigs_fn !{contigs}
        fi
        '''
}


process merge_pileup_and_full_vars{
    // Merge VCFs
    label "wf_somatic_snv"
    cpus 2
    memory 4.GB
    input:
        tuple val(meta), 
            path(pile_up_vcf), 
            path(pile_up_vcf_tbi), 
            path(full_aln_vcf), 
            path(full_aln_vcf_tbi), 
            path("non_var.gvcf"),
            path(ref), 
            path(fai), 
            path(ref_cache),
            env(REF_PATH),
            path(beds, stageAs: "candidate_beds/*"),
            val(contig)
        
        
    output:
        tuple val(meta), val(contig), path("output/merge_${meta.sample}_${meta.type}_${contig}.vcf.gz"), path("output/merge_${meta.sample}_${meta.type}_${contig}.vcf.gz.tbi"), emit: merged_vcf
        tuple val(meta), val(contig), path("output/merge_${meta.sample}_${meta.type}_${contig}.gvcf"), optional: true, emit: merged_gvcf

    shell:
        '''
        mkdir -p output
        echo "[INFO] 7/7 Merge pileup VCF and full-alignment VCF"
        pypy $(which clair3.py) MergeVcf \
            --pileup_vcf_fn !{pile_up_vcf} \
            --bed_fn_prefix candidate_beds \
            --full_alignment_vcf_fn !{full_aln_vcf} \
            --output_fn output/merge_!{meta.sample}_!{meta.type}_!{contig}.vcf \
            --platform ont \
            --print_ref_calls False \
            --gvcf !{params.GVCF} \
            --haploid_precise False \
            --haploid_sensitive False \
            --gvcf_fn "output/merge_!{meta.sample}_!{meta.type}_!{contig}.gvcf" \
            --non_var_gvcf_fn non_var.gvcf \
            --ref_fn !{ref} \
            --ctgName !{contig}

        bgzip -c output/merge_!{meta.sample}_!{meta.type}_!{contig}.vcf > output/merge_!{meta.sample}_!{meta.type}_!{contig}.vcf.gz
        tabix output/merge_!{meta.sample}_!{meta.type}_!{contig}.vcf.gz
        '''
}


process aggregate_all_variants{
    label "wf_somatic_snv"
    cpus 4
    memory { 4.GB * task.attempt }
    maxRetries 3
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta), 
            val(contigs), 
            path(vcfs, stageAs: "merge_output/*"), 
            path(tbis, stageAs: "merge_output/*"), 
            path(gvcf, stageAs: "merge_outputs_gvcf/*"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH), 
            path(contigs),
            path(command)
    output:
        tuple val(meta), path("${meta.sample}_${meta.type}_germline.vcf.gz"), path("${meta.sample}_${meta.type}_germline.vcf.gz.tbi"), emit: final_vcf
        tuple val(meta), path("${meta.sample}_${meta.type}_germline.gvcf.gz"), path("${meta.sample}_${meta.type}_germline.gvcf.gz.tbi"), emit: final_gvcf, optional: true
    shell:
        '''
        prefix="merge"
        ls merge_output/*.vcf.gz | parallel --jobs !{task.cpus} "bgzip -d {}"

        pypy $(which clair3.py) SortVcf \
            --input_dir merge_output \
            --vcf_fn_prefix $prefix \
            --output_fn !{meta.sample}_!{meta.type}_germline.vcf \
            --sampleName !{meta.sample} \
            --ref_fn !{ref} \
            --cmd_fn !{command} \
            --contigs_fn !{contigs}

        if [ "$( bcftools index --threads !{task.cpus} -n !{meta.sample}_!{meta.type}_germline.vcf.gz )" -eq 0 ]; then
            echo "[INFO] Exit in all contigs variant merging"
            exit 0
        fi

        # Also combine GVCFs
        if [ "!{params.GVCF}" == "true" ]; then
            pypy $(which clair3.py) SortVcf \
                --input_dir merge_outputs_gvcf \
                --vcf_fn_prefix $prefix \
                --vcf_fn_suffix .gvcf \
                --output_fn tmp.gvcf \
                --sampleName !{params.sample_name} \
                --ref_fn !{ref} \
                --cmd_fn !{command} \
                --contigs_fn !{contigs}

                # Reheading samples named "SAMPLE" to params.sample_name, fixing Clair3 mislabelling of the GVCF output.
                echo "SAMPLE" "!{params.sample_name}" > rename.txt
                bcftools reheader --threads !{task.cpus} -s rename.txt tmp.gvcf.gz > !{meta.sample}_!{meta.type}_germline.gvcf.gz
                bcftools index --threads !{task.cpus} -t "!{meta.sample}_!{meta.type}_germline.gvcf.gz" #&& rm tmp.gvcf.gz rename.txt
        fi

        echo "[INFO] Finish calling, output file: !{meta.sample}_!{meta.type}_germline.vcf.gz"
        '''
}
