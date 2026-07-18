#!/usr/bin/env python3
import json, subprocess, sys, datetime

RUN = sys.argv[1] if len(sys.argv) > 1 else "9960545"
tasks, token = [], None
while True:
    cmd = ["aws","omics","list-run-tasks","--id",RUN,"--region","ap-southeast-1",
           "--max-results","100","--output","json"]
    if token: cmd += ["--starting-token", token]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if not out.stdout.strip(): break
    j = json.loads(out.stdout)
    tasks += j.get("items", [])
    token = j.get("nextToken")
    if not token: break

now = datetime.datetime.now(datetime.timezone.utc)
def dur(t):
    s = t.get("startTime")
    if not s: return None
    end = datetime.datetime.fromisoformat(t["stopTime"]) if t.get("stopTime") else now
    return (end - datetime.datetime.fromisoformat(s)).total_seconds()/60.0

for key in ["clairs_phase", "phase_contig", "clairs_haplotag"]:
    ph = [t for t in tasks if key in t["name"]]
    if not ph: continue
    print(f"\n=== {key}: {len(ph)} tasks ===")
    rows = sorted(((dur(t), t["status"], t["name"], t.get("cpus"), t.get("memory"), t.get("instanceType")) for t in ph),
                  key=lambda r: (r[0] is None, r[0] or 0), reverse=True)
    for d,st,nm,cpu,mem,inst in rows[:8]:
        dd = f"{d:.1f}min" if d is not None else "n/a"
        print(f"  {st:10s} {dd:>9s} cpu={cpu} mem={mem} {inst} {nm[:45]}")
