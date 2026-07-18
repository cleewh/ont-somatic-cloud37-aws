import gzip, sys

def load(path):
    recs = []
    full = []
    with gzip.open(path, 'rt') as f:
        for line in f:
            if line.startswith('#'):
                continue
            c = line.rstrip('\n').split('\t')
            # CHROM POS ID REF ALT QUAL FILTER INFO FORMAT SAMPLE...
            chrom, pos, _id, ref, alt, qual, filt = c[0], c[1], c[2], c[3], c[4], c[5], c[6]
            fmt = c[8] if len(c) > 8 else ''
            samples = tuple(c[9:]) if len(c) > 9 else ()
            recs.append((chrom, pos, ref, alt))
            full.append((chrom, pos, ref, alt, qual, filt, fmt, samples))
    return recs, full

a_recs, a_full = load(sys.argv[1])
b_recs, b_full = load(sys.argv[2])

sa, sb = set(a_recs), set(b_recs)
print("Arm A (5mb) records:", len(a_recs))
print("Arm B (20mb) records:", len(b_recs))
print("shared (CHROM/POS/REF/ALT):", len(sa & sb))
print("A-only:", len(sa - sb))
print("B-only:", len(sb - sa))

# full-line (incl QUAL/FILTER/GT) comparison on shared positions
fa = {(r[0], r[1], r[2], r[3]): r for r in a_full}
fb = {(r[0], r[1], r[2], r[3]): r for r in b_full}
diff_fields = 0
for k in (sa & sb):
    if fa[k] != fb[k]:
        diff_fields += 1
print("shared positions with differing QUAL/FILTER/GT/etc:", diff_fields)

if sa == sb and diff_fields == 0:
    print("\nRESULT: IDENTICAL — somatic SNV calls (and all fields) match exactly.")
elif sa == sb:
    print("\nRESULT: same variant set; %d positions differ in annotation/qual/GT fields." % diff_fields)
    for k in list(sa & sb):
        if fa[k] != fb[k]:
            print("  A:", fa[k]); print("  B:", fb[k]); break
else:
    print("\nRESULT: variant SETS differ.")
    for k in list(sa - sb)[:5]: print("  A-only:", k)
    for k in list(sb - sa)[:5]: print("  B-only:", k)
