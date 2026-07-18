#!/usr/bin/env python3
"""Per-stage timing + rough cost for a HealthOmics run, from task start/stop times."""
import json, subprocess, sys, datetime, collections, re

RUN = sys.argv[1] if len(sys.argv) > 1 else "8384814"
import time
tasks, token = [], None
while True:
    cmd = ["aws","omics","list-run-tasks","--id",RUN,"--region","ap-southeast-1",
           "--max-results","100","--output","json"]
    if token: cmd += ["--starting-token", token]
    ok = False
    for attempt in range(6):
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.stdout.strip():
            ok = True; break
        time.sleep(2)
    if not ok:
        sys.stderr.write("giving up after retries; partial\n"); break
    j = json.loads(out.stdout)
    tasks += j.get("items", [])
    token = j.get("nextToken")
    if not token: break

now = datetime.datetime.now(datetime.timezone.utc)
def parse(t): return datetime.datetime.fromisoformat(t) if t else None
def dur(t):
    s = parse(t.get("startTime"))
    if not s: return 0.0
    e = parse(t.get("stopTime")) or now
    return (e - s).total_seconds()

# omics instance on-demand $/hr (ap-southeast-1, approx; omics.<fam>.<size>)
RATE = {"omics.c.large":0.1155,"omics.c.xlarge":0.231,"omics.c.2xlarge":0.462,"omics.c.4xlarge":0.924,
        "omics.c.8xlarge":1.848,"omics.c.12xlarge":2.772,
        "omics.m.large":0.1287,"omics.m.xlarge":0.2574,"omics.m.2xlarge":0.5148,"omics.m.4xlarge":1.0296,
        "omics.m.8xlarge":2.0592,"omics.m.12xlarge":3.0888,
        "omics.r.large":0.1699,"omics.r.xlarge":0.3398,"omics.r.2xlarge":0.6796,"omics.r.4xlarge":1.3592,
        "omics.r.8xlarge":2.7184,"omics.g4dn.xlarge":0.9464}

def stagekey(name):
    n = name.split("(")[0].strip()
    return n

agg = collections.defaultdict(lambda: {"n":0,"tasktime":0.0,"max":0.0,"first":None,"last":None,"cost":0.0,"running":0,"failed":0})
run_first, run_last = None, None
for t in tasks:
    k = stagekey(t["name"]); d = dur(t)
    a = agg[k]; a["n"]+=1; a["tasktime"]+=d; a["max"]=max(a["max"],d)
    s=parse(t.get("startTime")); e=parse(t.get("stopTime")) or now
    if s:
        a["first"]=min(a["first"],s) if a["first"] else s
        a["last"]=max(a["last"],e) if a["last"] else e
        run_first=min(run_first,s) if run_first else s
        run_last=max(run_last,e) if run_last else e
    if t["status"]=="RUNNING": a["running"]+=1
    if t["status"]=="FAILED": a["failed"]+=1
    # cost: billed max(task_seconds,60) * rate/3600 * (cpus/instance? no - instance rate already)
    inst=t.get("instanceType"); r=RATE.get(inst,0.0)
    billed=max(d,60.0)
    a["cost"]+= billed*r/3600.0

rows=sorted(agg.items(), key=lambda kv: kv[1]["tasktime"], reverse=True)
print(f"run {RUN}  total tasks {len(tasks)}")
if run_first: print(f"wall so far: {(run_last-run_first).total_seconds()/3600:.2f} h")
tot_cost=sum(a['cost'] for _,a in rows); tot_tt=sum(a['tasktime'] for _,a in rows)
print(f"total task-hours: {tot_tt/3600:.1f}   est task cost so far: ${tot_cost:.2f}\n")
print("%-42s %5s %9s %8s %9s %7s"%("stage","n","task-hr","max_min","stage_hr","cost$"))
for k,a in rows:
    stage_hr=(a["last"]-a["first"]).total_seconds()/3600 if a["first"] else 0
    flag=""
    if a["running"]: flag+=f" RUN={a['running']}"
    if a["failed"]: flag+=f" FAIL={a['failed']}"
    print("%-42s %5d %9.2f %8.1f %9.2f %7.2f%s"%(k[:42],a["n"],a["tasktime"]/3600,a["max"]/60,stage_hr,a["cost"],flag))
