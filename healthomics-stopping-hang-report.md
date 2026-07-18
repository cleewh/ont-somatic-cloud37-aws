Subject: AWS HealthOmics runs stuck in STOPPING (never reaching CANCELLED) — ap-southeast-1

Hi HealthOmics team,

We're hitting a control-plane issue where cancelled private-workflow runs record a
`stopTime` but never transition from `STOPPING` to `CANCELLED`. Several runs have been
wedged in `STOPPING` for many hours to over a day. Compute appears released (stopTime is
set), so this looks like a state-machine / finalize transition problem rather than a
compute issue on our side.

Account: 687677765589
Region:  ap-southeast-1
Engine:  NEXTFLOW (private workflow, workflowId 2590600)
Storage: DYNAMIC

Affected runs (all status=STOPPING, stopTime recorded, never reached CANCELLED):

| Run ARN | Name | startTime (UTC) | stopTime (UTC) | Stuck since stopTime |
|---------|------|-----------------|----------------|----------------------|
| arn:aws:omics:ap-southeast-1:687677765589:run/8974684 | colo829-cloud30-2tumor | 2026-07-14T14:13:59Z | 2026-07-15T07:51:53Z | ~29 h |
| arn:aws:omics:ap-southeast-1:687677765589:run/2337351 | colo829-cloud34-ubam | 2026-07-15T00:44:43Z | 2026-07-15T19:34:07Z | ~17 h |
| arn:aws:omics:ap-southeast-1:687677765589:run/6212644 | colo829-cloud35-ubam-persist | 2026-07-15T07:52:51Z | 2026-07-15T21:07:39Z | ~15.5 h |
| arn:aws:omics:ap-southeast-1:687677765589:run/4867299 | colo829-cloud36-c1-ubam-2tumor | 2026-07-15T20:39:55Z | 2026-07-16T05:40:06Z | ~7 h |

How they were stopped: each was cancelled via `aws omics cancel-run --id <id> --region
ap-southeast-1`. The API returned success and `stopTime` was populated, but the run status
has remained `STOPPING` since (verified via `get-run`).

Related symptom (same account/workflow): we have also observed runs hang at the FINALIZE
step near the end of an otherwise-complete run. Notably, an earlier run publishing an
equivalent ~628 GB output set completed normally, while later runs with comparable output
hung — which points to a transient service-side issue rather than output size or a defect
in our workflow definition.

Questions / requests:
1. Can you force these four runs to a terminal state (CANCELLED)?
2. Is the STOPPING→CANCELLED hang a known issue in ap-southeast-1, and is there a mitigation?
3. Is it related to the FINALIZE-step hang we've seen, and is there guidance to avoid it
   (e.g., output layout, storage type, concurrency, or run-group settings)?

Happy to provide CloudWatch logs, the workflow definition, or run any diagnostics you need.

Thanks,
[your name]
