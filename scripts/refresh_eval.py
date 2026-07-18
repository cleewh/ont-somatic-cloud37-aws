#!/usr/bin/env python3
"""Refresh /tmp/eval_<RUN>.json with all evaluate_candidates tasks (paginated)."""
import json, subprocess, sys

RUN = sys.argv[1] if len(sys.argv) > 1 else "9960545"
tasks = []
token = None
while True:
    cmd = ["aws", "omics", "list-run-tasks", "--id", RUN, "--region", "ap-southeast-1",
           "--max-results", "100", "--output", "json"]
    if token:
        cmd += ["--starting-token", token]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if not out.stdout.strip():
        sys.stderr.write("empty stdout; stderr=" + out.stderr[:300] + "\n")
        break
    j = json.loads(out.stdout)
    for t in j.get("items", []):
        nm = t.get("name", "")
        if "evaluate_candidates" in nm or "evaluate_candidates" in nm.lower():
            tasks.append({"taskId": t["taskId"], "status": t["status"],
                          "start": t.get("startTime"), "stop": t.get("stopTime"),
                          "name": nm})
    token = j.get("nextToken")
    if not token:
        break

json.dump(tasks, open(f"/tmp/eval_{RUN}.json", "w"))
import collections
print("total eval tasks:", len(tasks))
print("status:", collections.Counter(t["status"] for t in tasks))
