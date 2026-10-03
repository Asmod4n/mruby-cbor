import sys, statistics, collections
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) == 4:
        d[(p[1], p[2], p[0])].append(float(p[3]))
arms = sys.argv[2:]
keys = sorted({(k[0], k[1]) for k in d})
print("op doc " + " ".join(arms) + " ratio")
for op, doc in keys:
    m = [statistics.median(d[(op, doc, a)]) if d[(op, doc, a)] else float("nan") for a in arms]
    print(op, doc, " ".join("%.2f" % x for x in m), "%.2f" % (m[-1] / m[0]) if m[0] else "")
