#!/usr/bin/env bash
# cloud37 B1c — per-input ALIGN job (runs as an AWS Batch job on on-demand EC2).
# Auto-detects uBAM vs aligned for ONE input BAM and produces an aligned+indexed
# BAM written DIRECTLY to S3 (no HealthOmics scratch/finalize involved).
#
# The minimap2 recipe is the same as the validated HealthOmics minimap2_alignment
# process (samtools reset -> fastq -> minimap2 lr:hq -> reheader -> sort --write-index),
# so alignment results stay concordant with cloud29/34/35. The reheader step merges the
# uBAM's own header into minimap2's, exactly like `workflow-glue reheader_samstream`
# there, so the aligned BAM keeps its @RG lines (sample, platform, basecaller model)
# and the upstream @PG history.
#
# Env (set by the Batch job definition / Step Functions):
#   IN_BAM     s3://.../input.(u)bam        input BAM (uBAM or aligned)
#   OUT_BAM    s3://.../<sample>/xxx_aligned.bam   destination (index -> OUT_BAM.bai)
#   REF        s3://.../GRCh38_no_alt_analysis_set.fna   reference (+ .fai sibling)
#   MAP_THREADS(=16) SORT_THREADS(=6) BAM2FQ_THREADS(=2)
#   WORK       local scratch dir (default /scratch)
set -euo pipefail

: "${IN_BAM:?}"; : "${OUT_BAM:?}"; : "${REF:?}"
MAP_THREADS="${MAP_THREADS:-16}"; SORT_THREADS="${SORT_THREADS:-6}"; BAM2FQ_THREADS="${BAM2FQ_THREADS:-2}"
# Unique per-job scratch dir + cleanup on exit, so a reused Batch instance is left
# clean for the next job (align scratch is ~500GB; leftovers otherwise fill the volume).
WORK="${WORK:-/scratch}"; WORK="${WORK%/}/job-${AWS_BATCH_JOB_ID:-$$}"
mkdir -p "$WORK"; cd "$WORK"
trap 'cd /; rm -rf "$WORK" 2>/dev/null || true' EXIT

# Merge SAM header blocks exactly like workflow-glue reheader_samstream: a later @HD
# wins, a later run of @SQ replaces earlier @SQ, @RG are de-duplicated by ID (a
# conflicting duplicate is an error), every @PG is linked into one chain (a @PG with
# no PP is attached to the previous @PG; a colliding ID becomes ID-<n> from one global
# counter, and later PP references follow the rename), @CO are kept.
MERGE_HEADER_AWK='
BEGIN { FS = "\t"; hd = "@HD\tVN:1.6\tSO:unknown"; nsuffix = 0 }
function tag(name,   i) {
    for (i = 2; i <= NF; i++) if (substr($i, 1, 3) == name ":") return substr($i, 4)
    return ""
}
$1 == "@HD" { hd = $0 }
$1 == "@SQ" { if (reset_sq) { nsq = 0; reset_sq = 0 } sq[++nsq] = $0 }
$1 == "@RG" {
    id = tag("ID")
    if (!(id in rg_line)) { rg_line[id] = $0; rg[++nrg] = $0 }
    else if (rg_line[id] != $0) { print "conflicting @RG with ID " id > "/dev/stderr"; bad = 1; exit }
}
$1 == "@PG" {
    id = tag("ID"); pp = tag("PP")
    if (id in seen) { new_id = id "-" nsuffix; nsuffix++; remap[id] = new_id }
    else { seen[id] = 1; new_id = id }
    if (pp != "" && !(pp in seen)) { print "@PG PP:" pp " seen before its ID" > "/dev/stderr"; bad = 1; exit }
    out = "@PG"
    for (i = 2; i <= NF; i++) {
        f = substr($i, 1, 3)
        if (f == "ID:") out = out "\tID:" new_id
        else if (f == "PP:") out = out "\tPP:" ((pp in remap) ? remap[pp] : pp)
        else out = out "\t" $i
    }
    if (pp == "" && last != "") out = out "\tPP:" last
    last = new_id
    pg[++npg] = out
}
$1 == "@CO" { co[++nco] = $0 }
{ if (nsq > 0 && $1 != "@SQ") reset_sq = 1 }
END {
    if (bad) exit 1
    print hd
    for (i = 1; i <= nsq; i++) print sq[i]
    for (i = 1; i <= nrg; i++) print rg[i]
    for (i = 1; i <= npg; i++) print pg[i]
    for (i = 1; i <= nco; i++) print co[i]
}'

# Filter between minimap2 and samtools sort: read minimap2's header (SAM QNAMEs never
# start with '@'), emit uBAM header + reset/fastq @PG + minimap2 header merged, then
# hand the alignment records straight through with cat (no per-record processing).
# reads.header, PG_RESET and PG_FASTQ are set before the pipeline runs.
splice_header() {
    local line first="" got=0
    : > mm2.header
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            @*) printf '%s\n' "$line" >> mm2.header ;;
            *)  first="$line"; got=1; break ;;
        esac
    done
    { cat reads.header; printf '%s\n%s\n' "$PG_RESET" "$PG_FASTQ"; cat mm2.header; } \
        | awk "$MERGE_HEADER_AWK"
    if [ "$got" -eq 1 ]; then printf '%s\n' "$first"; cat; fi
}

echo "[align_job] IN_BAM=$IN_BAM OUT_BAM=$OUT_BAM"
aws s3 cp "$IN_BAM" in.bam
aws s3 cp "$REF" ref.fna
aws s3 cp "${REF}.fai" ref.fna.fai || samtools faidx ref.fna

# --- classify: aligned vs uBAM ---
# Disable pipefail locally: `head -1` closes the pipe early, giving samtools a SIGPIPE
# (nonzero) that would otherwise corrupt the flag extraction under `set -o pipefail`.
set +o pipefail
SQ=$(samtools view -H in.bam 2>/dev/null | grep -c '^@SQ' || true)
FIRST_FLAG=$(samtools view in.bam 2>/dev/null | head -1 | awk '{print $2}' || true)
set -o pipefail
SQ=${SQ:-0}
FIRST_FLAG=${FIRST_FLAG:-4}
UNMAPPED=$(( FIRST_FLAG & 4 ))

if [ "$SQ" -gt 0 ] && [ "$UNMAPPED" -eq 0 ]; then
    echo "[align_job] input is ALIGNED (@SQ=$SQ) -> ensure index, no realign"
    mv in.bam out.bam
    samtools quickcheck out.bam
    samtools index -@ "$SORT_THREADS" out.bam
else
    echo "[align_job] input is uBAM (@SQ=$SQ) -> minimap2 align (recipe == HealthOmics minimap2_alignment)"
    RESET="samtools reset -x tp,cm,s1,s2,NM,MD,AS,SA,ms,nn,ts,cg,cs,dv,de,rl"
    FASTQ="samtools fastq -T 1"
    # The two header-less steps get the same @PG records reheader_samstream inserts.
    PG_RESET=$'@PG\tID:reset\tPN:samtools\tCL:'"$RESET"
    PG_FASTQ=$'@PG\tID:fastq\tPN:samtools\tCL:'"$FASTQ"
    samtools view -H --no-PG in.bam > reads.header || true
    $RESET --no-PG in.bam -o - \
      | $FASTQ -@ "$BAM2FQ_THREADS" - \
      | minimap2 -y -t "$MAP_THREADS" -a -x lr:hq --cap-kalloc 100m --cap-sw-mem 50m ref.fna - \
      | splice_header \
      | samtools sort -@ "$SORT_THREADS" --write-index -o out.bam##idx##out.bam.bai -O bam --reference ref.fna -
    samtools quickcheck out.bam
    echo "[align_job] header: $(samtools view -H out.bam | grep -c '^@RG') @RG, $(samtools view -H out.bam | grep -c '^@PG') @PG"
fi

# --- upload aligned + index directly to S3 ---
aws s3 cp out.bam "$OUT_BAM"
aws s3 cp out.bam.bai "${OUT_BAM}.bai"
echo "[align_job] DONE -> $OUT_BAM (+ .bai)"
