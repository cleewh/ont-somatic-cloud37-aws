#!/usr/bin/env python3
import json, subprocess, sys, collections, datetime

RUN = sys.argv[1] if len(sys.argv) > 1 else "9960545"
tasks, token, pages = [], None, 0
while True:
    cmd = ["aws","omics","list-run-tasks","--id",RUN,"--region","ap-southeast-1",
           "--max-results","100","--output","json"]
    if token: cmd += ["--starting-token", token]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if not out.stdout.strip(): break
    j = json.loads(out.stdout)
    tasks += j.get("items", [])
    token = j.get("nextToken"); pages += 1
    if not token: break
print(f"pages={pages} total tasks={len(tasks)}")
print("status:", dict(collections.Counter(t["status"] for t in tasks)))
now = datetime.datetime.now(datetime.timezone.utc)
for t in tasks:
    if t["status"] in ("RUNNING","FAILED","STARTING","PENDING"):
        st = t.get("startTime")
        el = ""
        if st:
            el = f"{(now-datetime.datetime.fromisoformat(st)).total_seconds()/60:.1f}min"
        print(f"  {t['status']:9s} tid={t['taskId']} {t['name'][:50]} start_elapsed={el}")
