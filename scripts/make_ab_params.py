import json
base = json.load(open("/tmp/params_cloud5.json"))
base["bed"] = "s3://ont-lrs-somatic-poc-apse1-687677765589/inputs/regions/chr20_21.bed"
# Focus the A/B on SNV calling only.
base["snv"] = True
base["sv"] = False
base["mod"] = False
base["diff_mod"] = False
base["annotation"] = False
# Skip the ~15min genome-wide merge_tumor by using the pre-merged tumor BAM
# (from the original POC) as a single bam_tumor. Both arms use the identical
# merged input, so the chunk-size A/B stays clean; just faster to iterate.
base["bam_tumor"] = "s3://ont-lrs-somatic-poc-apse1-687677765589/inputs/tumor_merged/merged_tumor.bam"
base.pop("bam_tumor2", None)
json.dump(base, open("/tmp/params_ab.json", "w"), indent=2)
print(json.dumps(base, indent=2))
