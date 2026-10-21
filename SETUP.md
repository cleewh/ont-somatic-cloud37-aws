# Set up the pipeline in your AWS account

This guide sets up the ONT somatic pipeline (`wf-somatic-variation` v1.5.1 on AWS Batch
and AWS HealthOmics) in **your own** AWS account, then runs your tumor–normal pairs.
Kiro runs the commands for you; you do a few one-time steps first.

- The pipeline runs only in **Asia Pacific (Singapore), `ap-southeast-1`**. Your data,
  compute and results stay there. Setup downloads ONT's public software and the public
  GRCh38 reference genome into that region.
- Everything is created in your account; nothing depends on anyone else's.
- Setup takes about 30 minutes and costs a few dollars. A pair at ~96x tumor / ~60x normal
  coverage then takes about 14 hours and costs about $32 in compute.
- It works from Windows 10/11 and macOS. On Windows, Kiro runs the commands in Git Bash,
  which you install in section 1.

## 1. Before you start (about 20 minutes, once)

1. **Get the code.**
   1. Open the GitHub invitation email for `ont-somatic-cloud37-aws` and choose
      **Accept invitation**. Sign in to GitHub, or create a free account, if asked.
   2. On the repository page, choose the green **Code** button, then **Download ZIP**.
   3. Put the folder where you'll keep it. Setup saves your settings in it, and you use it
      for every run.
      - **Windows:** in your Downloads folder, double-click `ont-somatic-cloud37-aws-main.zip`.
        Drag the `ont-somatic-cloud37-aws-main` folder inside it to your user folder,
        `C:\Users\<your name>`. Don't use Desktop or Documents if OneDrive syncs them.
      - **Mac:** double-click the ZIP and move the `ont-somatic-cloud37-aws-main` folder
        into your **Documents** folder.
2. **Install the tools.** Close Kiro first, or quit and reopen it afterwards, so it sees them.
   - **Git for Windows** (Windows only). It gives Kiro the bash terminal the scripts need.
     Download it from <https://git-scm.com/download/win>, run it and accept every default.
   - **AWS command-line tool (AWS CLI)**, version 2.32 or later. Windows:
     <https://awscli.amazonaws.com/AWSCLIV2.msi>. Mac:
     <https://awscli.amazonaws.com/AWSCLIV2.pkg>. Open it and follow the installer. If you
     already have the AWS CLI, run the installer anyway to update it.
   - **Python 3.** Windows: download the latest Python 3 installer from
     <https://www.python.org/downloads/windows/>. On its first screen, tick **Add python.exe
     to PATH**, then choose **Install Now**. Mac: if setup later says Python is missing, open
     the **Terminal** app, run `xcode-select --install` and follow the prompts.
3. **Open the folder in Kiro.** In Kiro, choose **File → Open Folder**, select the
   `ont-somatic-cloud37-aws-main` folder and choose **Open** (on Windows, **Select Folder**).
   If Kiro asks whether you trust this folder, choose to trust it. Otherwise Kiro asks about
   every command and doesn't load this project's instructions for Kiro.

   **Windows only: make Kiro use Git Bash.** Press **Ctrl+Shift+P**, type
   `Terminal: Select Default Profile`, press Enter and choose **Git Bash**. Kiro then runs
   its commands in Git Bash.
4. **Sign in to AWS.** Signing in to Kiro doesn't give it access to your AWS account; the
   AWS CLI signs in separately. In Kiro, choose **Terminal → New Terminal** (or press
   **Ctrl+`**). On Windows, check that the new terminal says `MINGW64` and its prompt ends
   in `$`; if not, repeat the Git Bash step above. Type this and press Enter:

   ```bash
   aws login
   ```

   A browser window opens. Sign in to AWS the way you sign in to the AWS console. Your
   user needs administrator access. Then check it worked:

   ```bash
   aws sts get-caller-identity
   ```

   It should show your 12-digit account number. The sign-in lasts up to 12 hours. After
   that, commands say your credentials expired, and you run `aws login` again.
5. **Raise your compute limit.** New AWS accounts can run only 5 virtual CPUs (vCPUs) at a
   time in Singapore, and the pipeline needs 128.
   1. While signed in to the AWS console, open
      <https://ap-southeast-1.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A>.
      It's **Service Quotas → Amazon Elastic Compute Cloud (Amazon EC2) → Running On-Demand
      Standard (A, C, D, H, I, M, R, T, Z) instances**. Check that the region at the top
      right is **Asia Pacific (Singapore)**.
   2. If **Applied account-level quota value** is below 128, choose **Request increase at
      account level**, enter `128` and choose **Request**.
   3. AWS emails you when it's approved, usually within minutes to a few days. You can
      do the setup in the meantime; runs only start once it's approved.

## 2. Ask Kiro to set it up

1. Open Kiro's chat panel. It's on the right; if it's closed, press **Ctrl+L** (Mac:
   **Cmd+L**). Type into the chat box; don't choose Spec or Plan.
2. Paste this prompt and send it:

   > Set up the pipeline in this folder in my AWS account by following SETUP.md section 3.
   > Run `bash bin/deploy.sh`. If it prints ACTION NEEDED, stop and tell me exactly what I
   > need to do. If it prints STARTED, keep running `bash bin/status.sh --wait` until it
   > prints READY or FAILED, then show me what it printed. Don't edit any files, don't use
   > any region other than ap-southeast-1, and don't change any pipeline settings.

3. Kiro shows each command and asks before running it. Choose **Allow**. To stop being
   asked for this project's commands, choose **Always allow**, change the pattern to
   `bash bin/*` and apply it to **This workspace**.

Setup takes about 30 minutes, and Kiro reports `READY` with your bucket name when it's
done. Write the bucket name down; you'll use it to upload data. Setup keeps running if you
close Kiro, as long as your computer stays on. If your computer sleeps or restarts, ask Kiro
to run `bash bin/deploy.sh` again; it carries on where it stopped.

## 3. What the setup does

Kiro runs two commands from the folder:

| Command | What it does |
|---|---|
| `bash bin/deploy.sh` | Checks the AWS CLI, Python and your sign-in. Creates your S3 bucket, `ont-somatic-<account number>-ap-southeast-1`, and finds your account's default network. Builds the workflow package and checks it against the validated version. Then starts the rest of the setup in the background and returns within about a minute. |
| `bash bin/status.sh --wait` | Prints `RUNNING`, `READY` or `FAILED`. While setup runs, it waits up to 90 seconds before answering. `READY` means it checked that every part is in place. |

The background part copies ONT's containers into your container registry (ECR), builds the
alignment container and puts the GRCh38 reference genome in your bucket. These three run
inside AWS (CodeBuild), so your own internet connection doesn't slow them down. It then
creates three CloudFormation stacks: `cloud37-build`, `cloud37-prereqs` and `cloud37`.

Setup leaves these files in the folder. Keep them:

- `setup.env`: your bucket and network settings
- `bootstrap.log`: the setup log
- `cloud37-variant-workflow.zip`: the workflow package

Both commands are safe to run again at any time.

**Without Kiro (AWS CloudShell).** CloudShell is a terminal inside the AWS console that's
already signed in, so you can skip step 4 of section 1.

1. Sign in to the AWS console, set the region at the top right to **Asia Pacific
   (Singapore)**, and choose the CloudShell icon (**>_**) in the top bar.
2. Choose **Actions → Upload file** and upload the ZIP from section 1.
3. Run `unzip -q ont-somatic-cloud37-aws-main.zip`, then `cd ont-somatic-cloud37-aws-main`.
4. Run `bash bin/deploy.sh`, then `bash bin/status.sh --wait` until it prints READY.

CloudShell closes after 20–30 minutes without typing, which stops the setup, so press Enter
now and then. If it closes, open it again, run `cd ont-somatic-cloud37-aws-main` and then
`bash bin/deploy.sh`. Don't download results into CloudShell; it has only 1 GB of space.

## 4. Run a tumor–normal pair

### 4.1 Upload the BAM files

Each pair needs one or two tumor BAM files (two when the tumor was sequenced on two flow
cells) and exactly one normal BAM file. They can be unaligned or aligned to GRCh38. Each
sample needs at least 20x coverage.

Ask Kiro, with your own sample name and file paths:

> Upload the BAM files for sample SAMPLE1 as described in SETUP.md section 4.1. Tumor
> files: D:/data/tumor_flowcell1.bam and D:/data/tumor_flowcell2.bam. Normal file:
> D:/data/normal.bam.

Kiro runs:

```bash
bash bin/upload.sh --sample SAMPLE1 --tumor "D:/data/tumor_flowcell1.bam" --tumor2 "D:/data/tumor_flowcell2.bam" --normal "D:/data/normal.bam"
```

- On Windows, write paths with forward slashes, as above. To get a file's path, right-click
  it in File Explorer, choose **Copy as path** and change each `\` to `/`. On a Mac, paths
  look like `/Users/you/data/normal.bam`.
- Leave out `--tumor2` when there's only one tumor file.
- The sample name may use letters, numbers, `-` and `_`.
- The files go to `s3://<your bucket>/inputs/SAMPLE1/`. The upload runs in the
  background; check it with `bash bin/upload.sh --sample SAMPLE1 --wait`. When it's done,
  it prints the exact command to start the run.
- A 130 GB file takes about an hour on a fast connection and much longer on a typical
  office one. If the upload stops, for example because your 12-hour sign-in ran out, run
  `aws login` and then the same upload command again. Files that already finished are
  skipped.

The files must be on this computer or on a drive it can open. To upload from another
computer, such as the server where your data is, copy this whole folder there (it includes
`setup.env`), install and sign in to the AWS CLI on it, and run the same command.

### 4.2 Start the run

Ask Kiro, with your sample name and your data's basecaller model:

> Start the pipeline run for sample SAMPLE1 as described in SETUP.md section 4.2. The
> basecaller model is dna_r10.4.1_e8.2_400bps_sup@v4.2.0.

Kiro runs the command the upload printed, for example:

```bash
bash bin/start-run.sh --sample SAMPLE1 --tumor s3://YOUR-BUCKET/inputs/SAMPLE1/tumor1.bam --tumor2 s3://YOUR-BUCKET/inputs/SAMPLE1/tumor2.bam --normal s3://YOUR-BUCKET/inputs/SAMPLE1/normal.bam --model dna_r10.4.1_e8.2_400bps_sup@v4.2.0
```

- `--model` is the basecaller model your data was made with. This workflow version accepts
  models up to `dna_r10.4.1_e8.2_400bps_sup@v4.2.0`; if yours isn't supported, the script
  lists the ones that are. Data made with a newer `sup` model, such as `@v4.3.0`, runs as
  `@v4.2.0`; that's how the validation data was run.
- Before it starts anything, the script checks that the files exist, the model is supported
  and your compute limit is high enough.
- It prints the run's name, for example `SAMPLE1-20261021-0930`. Note it down; you need it
  to check the run and get the results.

### 4.3 Check progress

Ask Kiro *"What's the status of run SAMPLE1-20261021-0930?"*. It runs:

```bash
bash bin/run-status.sh SAMPLE1-20261021-0930
```

| It prints | Meaning |
|---|---|
| `ALIGNING` | Aligning the BAM files on AWS Batch: about 5 hours at full coverage |
| `MERGING` | Combining the two tumor files: about 2 hours |
| `VARIANT CALLING` | Running in HealthOmics: about 9 hours |
| `COMPLETED` | Finished. Download the results (4.4) |
| `COMPLETED WITHOUT RESULTS` | Finished but made no variant calls, usually because a sample is below 20x coverage |
| `FAILED` | Stopped. It shows why; see section 5 |

`bash bin/run-status.sh` with no run name lists your recent runs.

### 4.4 Get the results

Ask Kiro *"Download the results of run SAMPLE1-20261021-0930."*. It runs:

```bash
bash bin/get-results.sh SAMPLE1-20261021-0930
```

This downloads the results into `results/SAMPLE1-20261021-0930/` in the folder: about 10 GB
for a full-coverage pair. The download runs in the background; run
`bash bin/get-results.sh SAMPLE1-20261021-0930 --wait` to check on it, and it prints `DONE`
when it's finished. You get:

- somatic SNV and indel VCFs, plus tumor and normal germline VCFs, in `<sample>/snv/vcf/`
- structural variants from Severus, in `<sample>/sv/`
- 5mC and 5hmC methylation with DSS differential methylation, in `<sample>/mod/`
- HTML reports, named `*report.html`

The BAM and CRAM files stay in S3, in `s3://YOUR-BUCKET/outputs/<run name>/`. That includes
the aligned BAMs in `aligned_bams/`, so variant calling can be re-run without aligning again.

## 5. If something goes wrong

| Message | What it means | What to do |
|---|---|---|
| `bash: command not found`, `The term 'bash' is not recognized`, or a message about Windows Subsystem for Linux | Windows: Kiro isn't using Git Bash | Install Git for Windows (section 1, step 2), then do the Git Bash step in section 1, step 3 |
| `install the AWS CLI`, or `aws: command not found` | The AWS CLI isn't installed, or Kiro was open during the install | Section 1, step 2, then quit and reopen Kiro |
| `install Python 3.8 or later`, or `Python was not found` | Python is missing | Section 1, step 2 (on Windows, tick **Add python.exe to PATH**), then quit and reopen Kiro. Mac: in the Terminal app, run `xcode-select --install` |
| `isn't signed in`, `ExpiredToken`, `Unable to locate credentials` | Not signed in, or the 12-hour sign-in ran out | Run `aws login` in Kiro's terminal (section 1, step 4), then the same command again |
| `NOTE: your EC2 limit in Singapore is 5 vCPUs` | The compute limit hasn't been raised yet | Section 1, step 5. Setup can carry on |
| `alignment can't start`, or a note that jobs have waited more than 15 minutes for computers | The compute limit is too low | Section 1, step 5, then start the run again |
| `FAILED` with `toomanyrequests` | Docker Hub's download limit was hit | Wait an hour, then run `bash bin/deploy.sh` |
| `FAILED` with `Cannot have more than 0 builds in queue` | New accounts can have a CodeBuild limit of 0 | In Service Quotas, open **AWS CodeBuild → Concurrently running builds for Linux/Medium environment** and request 1 or more, or ask AWS Support. Then run `bash bin/deploy.sh` |
| `FAILED` with `_IN_PROGRESS state` | An earlier attempt is still finishing | Wait 5 minutes, then run `bash bin/deploy.sh` |
| Setup `FAILED` for another reason | | Run `bash bin/deploy.sh` once more. If it fails the same way, ask Kiro: *"Why did the setup fail? Read bootstrap.log."* |
| A run `FAILED` | | Ask Kiro: *"Why did run RUN-NAME fail?"* |
| `COMPLETED WITHOUT RESULTS` | A sample is below 20x coverage | Each sample needs 20x or more |
| Kiro says shell integration is unavailable, or a command stays on "Working…" | Kiro's terminal isn't set up | Press **Ctrl+Shift+P** (Mac: **Cmd+Shift+P**), run **Kiro: Enable Shell Integration**, then quit and reopen Kiro |

## 6. Costs and clean-up

- Compute runs only while a pair is processing and stops on its own afterwards.
- Storage is the ongoing cost. A full-coverage pair leaves about 1.4 TB in S3, about $35 a
  month, mostly BAM and CRAM files. Once you've downloaded the results, delete what you
  don't need, for example a run's aligned BAMs:
  `aws s3 rm s3://YOUR-BUCKET/outputs/RUN-NAME/aligned_bams/ --recursive`
- Set a spending alert: in the AWS console, open **Billing and Cost Management → Budgets →
  Create budget**.
- To remove the pipeline, run these three commands. Your bucket and its data stay until you
  delete them yourself.

  ```bash
  aws cloudformation delete-stack --region ap-southeast-1 --stack-name cloud37
  aws cloudformation delete-stack --region ap-southeast-1 --stack-name cloud37-prereqs
  aws cloudformation delete-stack --region ap-southeast-1 --stack-name cloud37-build
  ```

  The copied containers also stay in ECR: about 10 GB, roughly $1 a month. To remove them,
  ask Kiro: *"Delete the ECR repositories cloud37-align and docker-hub/ontresearch/\* in
  ap-southeast-1."*

## Licence

The ONT workflow and containers are licensed under the Oxford Nanopore Technologies PLC.
Public License v1.0, for research use only (`production/cloud-pipeline/LICENSE`). Setup
downloads them directly from ONT (GitHub and Docker Hub) into your account.
