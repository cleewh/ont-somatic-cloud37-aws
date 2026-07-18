import json, sys, re
from collections import Counter, defaultdict
f = sys.argv[1]
data = json.load(open(f))
proc = Counter()
status = Counter()
procstatus = defaultdict(Counter)
for t in data:
    n = t.get('name','?')
    s = t.get('status','?')
    status[s]+=1
    base = re.sub(r'\s*\(\d+\)$','',n)
    proc[base]+=1
    procstatus[base][s]+=1
print("=== STATUS TOTALS ===")
for k,v in status.most_common(): print(f"{v:5d}  {k}")
print("=== BY PROCESS ===")
for base in sorted(procstatus):
    sc = procstatus[base]
    print(f"{sum(sc.values()):5d}  {base}  {dict(sc)}")
