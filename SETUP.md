# Set up the pipeline in your AWS account

This guide installs the ONT somatic pipeline (`wf-somatic-variation` v1.5.1 on AWS Batch
and AWS HealthOmics) in **your own** AWS account and runs your first tumor–normal pair.
Kiro can run every command for you; the same steps also work by hand in AWS CloudShell.

Everything is created in your account and nothing depends on anyone else's. Setup takes
about an hour, mostly waiting, and costs a few dollars. A pair at ~96x tumor / ~60x
normal coverage then takes about 14 hours and costs about $32 in compute.

## 1. Before you start (you, about 10 minutes)

1. **Get the code.** Accept the GitHub invitation to `ont-somatic-cloud37-aws`. On the
   repository page choose **Code → Download ZIP**, unzip it, and open the folder in Kiro
   (**File → Open Folder**).
2. **Check Kiro's AWS connection.** It should use your account with administrator
   access. The pipeline runs in **Asia Pacific (Singapore), `ap-southeast-1`**.
3. **Check your compute limit.** New AWS accounts often can't start the 32-CPU machines
   the alignment uses. In the AWS console open **Service Quotas → AWS services → Amazon
   Elastic Compute Cloud (Amazon EC2)**, search for **Running On-Demand Standard (A, C, D,
   H, I, M, R, T, Z) instances**, and check the applied value for ap-southeast-1. If it is
   below **128**, choose **Request increase at account level**, enter `128`, and submit.
   Approval can take from minutes to a couple of days. You can set up in the meantime,
   but runs only start once it's approved.
4. **On Windows**, Kiro needs a bash terminal (WSL or Git Bash). Without one, use the
   CloudShell route at the end of section 3.

## 2. Ask Kiro to deploy it

Paste this into Kiro's chat:

> Deploy this pipeline into my AWS account by following SETUP.md section 3, "Deployment
> steps", in order. Use region ap-southeast-1. Check the prerequisites first and tell me
> if anything needs my action. Don't change any pipeline settings (instance types, CPUs,
> memory). When it finishes, show me the results of the "Done when" check.

Kiro creates a storage bucket, builds the workflow package, and runs the setup script.
That takes 30–45 minutes, mostly waiting on AWS. If a step fails, ask Kiro to explain
the error and re-run that step. The setup skips work that is already done.

## 3. Deployment steps

These are the exact steps Kiro follows. Run them from the repository folder.

**3.1 Prerequisites**

```bash
aws --version                       # AWS CLI v2
aws sts get-caller-identity         # must show your account
export AWS_REGION=ap-southeast-1 AWS_DEFAULT_REGION=ap-southeast-1
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text   # 128 or more; see section 1, item 3
```

**3.2 Bucket and network**

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=ont-somatic-${ACCOUNT}-${AWS_REGION}
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || aws s3 mb "s3://$BUCKET"

VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
export SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
export SECURITY_GROUP=$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text)
echo "$VPC $SUBNETS $SECURITY_GROUP"
```

If `VPC` prints `None`, the account has no default network. Ask your IT team for subnets
with internet access and a security group that allows outbound HTTPS, and set `SUBNETS`
(comma-separated) and `SECURITY_GROUP` to those.

**3.3 Build the workflow package**

```bash
python3 production/cloud-pipeline/build_workflow_zip.py
```

This downloads ONT's workflow from GitHub and adds the cloud changes. The output must
end with `content matches the validated HealthOmics workflow (cloud37-variant-rs3)`.

**3.4 Run the setup** (30–45 minutes)

```bash
bash production/cloud37/bootstrap.sh "$AWS_REGION" "$BUCKET" cloud37-variant-workflow.zip
```

It copies the ONT containers into your container registry (ECR), builds the alignment
container with CodeBuild, puts the GRCh38 reference genome in your bucket, and creates
three CloudFormation stacks.

- It's safe to re-run if it stops partway. Export `BUCKET`, `SUBNETS` and
  `SECURITY_GROUP` again first.
- If CodeBuild fails with `toomanyrequests`, Docker Hub's download limit was hit. Wait an
  hour and re-run.

**3.5 Done when**

```bash
for s in cloud37-build cloud37-prereqs cloud37; do
  aws cloudformation describe-stacks --stack-name "$s" --query 'Stacks[0].StackStatus' --output text
done                                                    # all three end in _COMPLETE
aws cloudformation describe-stacks --stack-name cloud37 \
  --query "Stacks[0].Outputs[?OutputKey=='StateMachineArn'].OutputValue" --output text
aws omics list-workflows --name cloud37-variant-caller --query 'items[0].status' --output text   # ACTIVE
```

In HealthOmics the workflow is `cloud37-variant-caller`, version `cloud37-variant`. That
version holds the validated rs3 definition; step 3.3 checks this.

**Without Kiro (AWS CloudShell):** in the AWS console, click the CloudShell icon in the
top bar. Choose **Actions → Upload file** and upload the ZIP from section 1. Then run
`unzip ont-somatic-cloud37-aws-main.zip && cd ont-somatic-cloud37-aws-main` and the
commands in 3.1–3.5. CloudShell closes after about 20–30 minutes without keyboard input,
so press Enter in it now and then during 3.4. If it closes, reopen it, `cd` into the
folder, and continue from 3.2.

## 4. Run a tumor–normal pair

**4.1 Upload the BAMs.** They can be unaligned or aligned, one file per flow cell. Keep
inputs under `inputs/` and results under `outputs/` in your bucket, because the
HealthOmics role can only read and write there.

```bash
aws s3 cp tumor_flowcell1.bam s3://$BUCKET/inputs/SAMPLE1/tumor1.bam
aws s3 cp tumor_flowcell2.bam s3://$BUCKET/inputs/SAMPLE1/tumor2.bam   # only if there is a second tumor file
aws s3 cp normal.bam          s3://$BUCKET/inputs/SAMPLE1/normal.bam
```

Run the upload on the computer or server where the BAMs are stored. Uploading 100+ GB
takes hours on a typical office connection.

**4.2 Start the run**

```bash
SM=$(aws cloudformation describe-stacks --stack-name cloud37 \
  --query "Stacks[0].Outputs[?OutputKey=='StateMachineArn'].OutputValue" --output text)
cat > pair.json <<JSON
{
  "sample_name": "SAMPLE1",
  "bam_tumor":  "s3://$BUCKET/inputs/SAMPLE1/tumor1.bam",
  "bam_tumor2": "s3://$BUCKET/inputs/SAMPLE1/tumor2.bam",
  "bam_normal": "s3://$BUCKET/inputs/SAMPLE1/normal.bam",
  "ref":        "s3://$BUCKET/inputs/references/GRCh38_no_alt_analysis_set.fna",
  "output_prefix": "s3://$BUCKET/outputs/SAMPLE1-run1/",
  "override_basecaller_cfg": "dna_r10.4.1_e8.2_400bps_sup@v4.2.0"
}
JSON
aws stepfunctions start-execution --state-machine-arn "$SM" --name SAMPLE1-run1 --input file://pair.json
```

- Delete the `bam_tumor2` line if there is only one tumor file.
- `output_prefix` must end with `/`, and each run needs its own execution name.
- Set `override_basecaller_cfg` to your data's basecaller model. This workflow version
  accepts models up to `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`; the validation data was
  basecalled with `@v4.3.0` and run as `@v4.2.0`.
- Each sample needs at least 20x coverage. Below that, the workflow skips the pair.

With Kiro, you can ask: *"Start the pipeline for sample SAMPLE1 with tumor files s3://…
and s3://… and normal file s3://…, following SETUP.md section 4."*

**4.3 Watch it.** In the Step Functions console, open state machine
`cloud37-align-then-variant` and then your execution. It shows alignment and merge
(about 5 hours at full coverage), then starts the HealthOmics run and finishes. Variant
calling continues under **HealthOmics → Runs** (about 9 hours). The run ID is also in
`s3://$BUCKET/outputs/SAMPLE1-run1/manifest.json`.

**4.4 Results** are in `s3://$BUCKET/outputs/SAMPLE1-run1/<run-id>/definition/output/`:

- somatic SNV and indel VCFs, plus germline VCFs
- structural variants (Severus)
- 5mC/5hmC methylation with DSS
- HTML QC reports

The aligned BAMs stay in `outputs/SAMPLE1-run1/aligned_bams/`, so the variant calling
can be re-run without re-aligning.

## 5. If something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| Batch jobs stay `RUNNABLE` for more than 15 minutes | Compute limit too low | Section 1, item 3 |
| CodeBuild fails with `toomanyrequests` | Docker Hub download limit | Wait an hour, re-run 3.4 |
| Setup stopped partway | Session closed or a temporary error | Re-run 3.4 |
| HealthOmics run `FAILED` | Shown by `aws omics get-run --id <run-id> --query failureReason` | Ask Kiro to read the run's logs |
| Log says a sample is "below the minimum coverage" | Tumor or normal under 20x | Needs 20x or more per sample |

## 6. Costs and clean-up

- Compute runs only while a pair is processing and stops on its own afterwards.
- Storage is the ongoing cost. A full-coverage pair leaves about 1.4 TB in S3, about $35
  a month. Most of that is BAM/CRAM copies; keep the VCFs and reports, and delete the
  rest when you no longer need it:
  `aws s3 rm s3://$BUCKET/outputs/SAMPLE1-run1/aligned_bams/ --recursive`
- Set a spending alert under **Billing → Budgets**.
- To remove the pipeline, delete the stacks `cloud37`, `cloud37-prereqs` and
  `cloud37-build` in CloudFormation. Your S3 data stays until you delete it.

## Licence

The ONT workflow and containers are licensed under the Oxford Nanopore Technologies PLC.
Public License v1.0, for research use only (`production/cloud-pipeline/LICENSE`). Setup
downloads them directly from ONT (GitHub and Docker Hub) into your account.
