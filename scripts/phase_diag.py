#!/usr/bin/env python3
"""Diagnose the chr1 phase hang: for each clairs_phase task, pull its log, extract the
contig (Output Prefix), duration, and any longphase progress/het-count signals. Compare
the hung chr1 task vs fast contigs (esp. chr4, the deeper-but-fast one)."""
import json, subprocess, sys, re, datetime
from concurrent.futures import ThreadPoolExecutor

RUN = sys.argv[1] if len(sys.argv) > 1 else "8384814"
tasks, token = [], None
while True:
    cmd = ["aws","omics","list-run-tasks","--id",RUN,"--region","ap-southeast-1",
           "--max-results","100","--output","json"]
    if token: cmd += ["--starting-token", token]
    import time
    o=None
    for _ in range(6):
        o=subprocess.run(cmd,capture_output=True,text=True)
        if o.stdout.strip(): break
        time.sleep(2)
    if not o.stdout.strip(): break
    j=json.loads(o.stdout); tasks+=j.get("items",[])
    token=j.get("nextToken")
    if not token: break

now=datetime.datetime.now(datetime.timezone.utc)
def dur(t):
    s=t.get("startTime")
    if not s: return None
    e=datetime.datetime.fromisoformat(t["stopTime"]) if t.get("stopTime") else now
    return (e-datetime.datetime.fromisoformat(s)).total_seconds()/60.0
ph=[t for t in tasks if "clairs_phase" in t["name"]]

def pull(t):
    tid=t["taskId"]
    try:
        o=subprocess.run(["aws","logs","get-log-events","--log-group-name","/aws/omics/WorkflowLog",
          "--log-stream-name",f"run/{RUN}/task/{tid}","--region","ap-southeast-1","--start-from-head",
          "--output","text","--query","events[*].message"],capture_output=True,text=True,timeout=60)
        msgs=o.stdout
        ctg=re.search(r"phased_\S+_tumor_(\S+)", msgs)
        ctg=ctg.group(1).strip() if ctg else "?"
        nlines=len(msgs.split("\t"))
        # longphase may print progress; capture last non-empty token
        toks=[x.strip() for x in msgs.split("\t") if x.strip()]
        last=toks[-1][:60] if toks else ""
        return (ctg, dur(t), t["status"], nlines, last)
    except Exception as ex:
        return ("ERR", dur(t), t["status"], 0, str(ex)[:40])

rows=list(ThreadPoolExecutor(max_workers=12).map(pull, ph))
rows.sort(key=lambda r:(r[1] or 0), reverse=True)
print("%-8s %8s %-10s %6s  %s"%("contig","dur_min","status","logtoks","last_log_token"))
for ctg,d,st,nl,last in rows:
    print("%-8s %8.1f %-10s %6d  %s"%(ctg, d or 0, st, nl, last))
