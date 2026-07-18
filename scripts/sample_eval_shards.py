import json, subprocess, re, datetime

RUN = "6488348"
d = json.load(open("/tmp/c20eval.json"))
now = datetime.datetime.now(datetime.timezone.utc)

def dur(t):
    s = t.get("start")
    if not s: return None
    end = datetime.datetime.fromisoformat(t["stop"]) if t.get("stop") else now
    return (end - datetime.datetime.fromisoformat(s)).total_seconds() / 60

comp = [(dur(t), t["taskId"]) for t in d if t["status"] == "COMPLETED" and dur(t) is not None]
comp.sort()
n = len(comp)
# sample across the distribution: fastest few, quartiles, slowest many
idxs = sorted(set([0,1,2, n//4, n//2, int(n*0.75), int(n*0.9), int(n*0.95), int(n*0.99)] + list(range(n-12, n))))
idxs = [i for i in idxs if 0 <= i < n]

rows = []
for i in idxs:
    mins, tid = comp[i]
    try:
        out = subprocess.run(
            ["aws","logs","get-log-events","--log-group-name","/aws/omics/WorkflowLog",
             "--log-stream-name", f"run/{RUN}/task/{tid}","--region","ap-southeast-1","--output","json"],
            capture_output=True, text=True, timeout=60)
        j = json.loads(out.stdout)
        msgs = " ".join(e["message"] for e in j.get("events", []))
        pos = re.search(r"processed positions in (\S+)\s*:\s*(\d+)", msgs)
        el = re.search(r"Total time elapsed:\s*([\d.]+)\s*s", msgs)
        ctg = pos.group(1) if pos else "?"
        npos = int(pos.group(2)) if pos else -1
        secs = float(el.group(1)) if el else mins*60
        rows.append((mins, ctg, npos, secs))
    except Exception as ex:
        rows.append((mins, "ERR", -1, mins*60))

print("%-8s %-7s %-10s %-8s" % ("min", "contig", "positions", "sec"))
for mins, ctg, npos, secs in rows:
    print("%-8.2f %-7s %-10d %-8.0f" % (mins, ctg, npos, secs))
# crude correlation positions vs sec
good = [(p,s) for _,c,p,s in rows if p>0]
if len(good) > 2:
    import statistics
    ps=[p for p,s in good]; ss=[s for p,s in good]
    mp=statistics.mean(ps); ms=statistics.mean(ss)
    cov=sum((p-mp)*(s-ms) for p,s in good); vp=sum((p-mp)**2 for p in ps); vs=sum((s-ms)**2 for s in ss)
    r = cov/((vp*vs)**0.5) if vp>0 and vs>0 else 0
    print("\npositions-vs-seconds Pearson r = %.3f (n=%d)" % (r, len(good)))
    print("sec per position (slope-ish): %.4f" % (sum(ss)/sum(ps)))
