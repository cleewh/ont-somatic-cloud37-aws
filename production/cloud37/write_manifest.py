"""cloud37 B1c - Lambda: write manifest.json to the per-pair output prefix.
Invoked by the Step Functions state machine AFTER StartRun, so the manifest is the
single source of truth for the pair (source inputs, aligned BAM URIs, HealthOmics run).
Event (from SFN):
  {
    "output_prefix": "s3://.../outputs/<sample>-<ts>/",
    "sample_name": "COLO829",
    "sources": {"bam_tumor": "...", "bam_tumor2": "..."|null, "bam_normal": "..."},
    "aligned": {"tumor": "s3://.../aligned_bams/tumor_aligned.bam",
                "normal": "s3://.../aligned_bams/normal_aligned.bam"},
    "healthomics_run_id": "1234567",
    "healthomics_run_output_uri": "s3://.../<run-id>"
  }
"""
import json, datetime, urllib.parse
import boto3

s3 = boto3.client("s3")


def handler(event, context):
    prefix = event["output_prefix"].rstrip("/") + "/"
    p = urllib.parse.urlparse(prefix)
    bucket, key = p.netloc, p.path.lstrip("/") + "manifest.json"

    manifest = {
        "schema": "cloud37-b1c/1",
        "sample_name": event["sample_name"],
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_inputs": event.get("sources", {}),
        "aligned_bams": event.get("aligned", {}),
        "healthomics": {
            "run_id": event.get("healthomics_run_id"),
            "run_output_uri": event.get("healthomics_run_output_uri"),
            "variant_outputs": (event.get("healthomics_run_output_uri", "").rstrip("/")
                                + "/definition/output/") if event.get("healthomics_run_output_uri") else None,
        },
        "layout_note": "aligned_bams/ + manifest.json sit at the output-uri prefix; "
                       "HealthOmics variant outputs are under <run-id>/definition/output/",
    }
    body = json.dumps(manifest, indent=2).encode()
    s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/json")
    return {"manifest_uri": f"s3://{bucket}/{key}", "manifest": manifest}
