#!/usr/bin/env python3
"""Estimate the eval cost exponent p (cost ~ depth^p) from eval-shard logs.
Each shard log has 'processed positions in <ctg> : P' and 'Total time elapsed: T s'.
per-candidate cost = T/P. We can't read depth directly, but per-position cost spans
the depth range; p = log(cost_ratio)/log(depth_ratio) under a depth-range assumption.
Also groups by contig (centromeric contigs run deeper)."""
import json, subprocess, re, datetime, math, statistics, sys
RUN = sys.argv[1] if len(sys.argv)>1 else "9960545"
NSAMPLE = int(sys.argv[2]) if len(sys.argv)>2 else 60

d = json.load(open(f"/tmp/eval_{RUN}.json"))
now = datetime.datetime.now(datetime.timezone.utc)
def dur(t):
    s=t.get('start')
    if not s: return None
    end=datetime.datetime.fromisoformat(t['stop']) if t.get('stop') else now
    return (end-datetime.datetime.fromisoformat(s)).total_seconds()
comp=[(dur(t),t['taskId']) for t in d if t['status']=='COMPLETED' and dur(t) is not None]
comp.sort()
n=len(comp)
# stratified sample across duration range (want both fast/shallow and slow/deep)
idx=sorted(set(int(n*f) for f in [i/NSAMPLE for i in range(NSAMPLE)]+[0.995,0.999,1.0]))
idx=[min(i,n-1) for i in idx]
rows=[]
for i in idx:
    secs,tid=comp[i]
    try:
        out=subprocess.run(["aws","logs","get-log-events","--log-group-name","/aws/omics/WorkflowLog",
          "--log-stream-name",f"run/{RUN}/task/{tid}","--region","ap-southeast-1","--output","json"],
          capture_output=True,text=True,timeout=60)
        j=json.loads(out.stdout); msgs=" ".join(e["message"] for e in j.get("events",[]))
        m=re.search(r"processed positions in (\S+)\s*:\s*(\d+)",msgs)
        el=re.search(r"Total time elapsed:\s*([\d.]+)\s*s",msgs)
        if m and el:
            ctg=m.group(1); P=int(m.group(2)); T=float(el.group(1))
            if P>0: rows.append((ctg,P,T,T/P))
    except Exception: pass

rows.sort(key=lambda r:r[3])
print("%-7s %8s %9s %10s"%("contig","positions","T_clair_s","s/pos"))
for ctg,P,T,sp in rows: print("%-7s %8d %9.1f %10.5f"%(ctg,P,T,sp))
sps=[r[3] for r in rows]
if len(sps)>=3:
    lo=min(sps); hi=max(sps); ratio=hi/lo
    print(f"\nper-candidate cost: min {lo:.5f}  max {hi:.5f}  RATIO {ratio:.0f}x  (n={len(rows)})")
    print("p estimate for assumed depth ratios (deepest satellite / normal):")
    for dr in [10,20,33,50,80]:
        print(f"   depth_ratio={dr:>3}x  ->  p = log(cost_ratio)/log(depth_ratio) = {math.log(ratio)/math.log(dr):.2f}")
