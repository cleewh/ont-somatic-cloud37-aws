#!/usr/bin/env python3
import json, subprocess, sys, time
RUN = sys.argv[1]; NEEDLE = sys.argv[2]
tasks, token = [], None
while True:
    cmd = ["aws","omics","list-run-tasks","--id",RUN,"--region","ap-southeast-1","--max-results","100","--output","json"]
    if token: cmd += ["--starting-token", token]
    ok=False
    for _ in range(6):
        o=subprocess.run(cmd,capture_output=True,text=True)
        if o.stdout.strip(): ok=True; break
        time.sleep(2)
    if not ok: break
    j=json.loads(o.stdout); tasks+=j.get("items",[])
    token=j.get("nextToken")
    if not token: break
hits=[t for t in tasks if NEEDLE in t["name"]]
print(f"total tasks {len(tasks)}; matches for '{NEEDLE}': {len(hits)}")
for t in hits:
    print(f"  taskId={t['taskId']} status={t['status']} cpus={t.get('cpus')} mem={t.get('memory')} name={t['name']}")
