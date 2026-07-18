import json, subprocess, re, datetime, statistics, math, sys

RUN = sys.argv[1] if len(sys.argv) > 1 else "1979250"
d = json.load(open(f"/tmp/eval_{RUN}.json"))
now = datetime.datetime.now(datetime.timezone.utc)

def dur(t):
    s = t.get("start")
    if not s: return None
    end = datetime.datetime.fromisoformat(t["stop"]) if t.get("stop") else now
    return (end - datetime.datetime.fromisoformat(s)).total_seconds()

comp = [(dur(t), t["taskId"]) for t in d if t["status"] == "COMPLETED" and dur(t) is not None]
comp.sort()
n = len(comp)
# stratified sample across the duration distribution
picks = sorted(set(int(n*f) for f in [0.02,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.85,0.9,0.93,0.96,0.98,0.99,0.995,0.999]))
picks = [min(p, n-1) for p in picks]
rows = []
for i in picks:
    secs, tid = comp[i]
    try:
        out = subprocess.run(["aws","logs","get-log-events","--log-group-name","/aws/omics/WorkflowLog",
            "--log-stream-name", f"run/{RUN}/task/{tid}","--region","ap-southeast-1","--output","json"],
            capture_output=True, text=True, timeout=60)
        j = json.loads(out.stdout); msgs = " ".join(e["message"] for e in j.get("events", []))
        m = re.search(r"processed positions in (\S+)\s*:\s*(\d+)", msgs)
        el = re.search(r"Total time elapsed:\s*([\d.]+)\s*s", msgs)
        ctg = m.group(1) if m else "?"; pos = int(m.group(2)) if m else -1
        t_log = float(el.group(1)) if el else secs
        rows.append((ctg, pos, t_log, secs))
    except Exception as ex:
        rows.append(("ERR", -1, secs, secs))

print("%-7s %10s %9s %9s %10s" % ("contig","positions","t_log_s","task_s","s/pos"))
good=[]
for ctg,pos,tl,ts in rows:
    sp = tl/pos if pos>0 else float('nan')
    print("%-7s %10d %9.0f %9.0f %10.5f" % (ctg,pos,tl,ts,sp))
    if pos>0 and tl>0: good.append((pos,tl,ctg))

if len(good)>=3:
    xs=[math.log(p) for p,t,c in good]; ys=[math.log(t) for p,t,c in good]
    mx=statistics.mean(xs); my=statistics.mean(ys)
    b=sum((x-mx)*(y-my) for x,y in zip(xs,ys))/sum((x-mx)**2 for x in xs)
    a=my-b*mx
    # R^2 in log-log
    ss_res=sum((y-(a+b*x))**2 for x,y in zip(xs,ys)); ss_tot=sum((y-my)**2 for y in ys)
    r2=1-ss_res/ss_tot if ss_tot>0 else 0
    print("\nlog-log fit: time ~ positions^%.3f  (R^2=%.3f, n=%d)"%(b,r2,len(good)))
    sps=[t/p for p,t,c in good]
    print("s/position: mean %.5f  min %.5f  max %.5f  CV %.2f"%(statistics.mean(sps),min(sps),max(sps),statistics.pstdev(sps)/statistics.mean(sps)))
