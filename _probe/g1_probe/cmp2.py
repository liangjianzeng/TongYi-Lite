import re, sys
a = open(sys.argv[1]).read()   # baseline mm (repack ON)
b = open(sys.argv[2]).read()   # fused raw (NO_REPACK)
ra = re.findall(r'row0_hex=([0-9a-f]+)', a)
rb = re.findall(r'wq_row0_hex=([0-9a-f]+)', b)
print("baseline bytes len", len(ra), "fused bytes len", len(rb))
if ra and rb:
    print("IDENTICAL?", ra[0] == rb[0])
    print("baseline[:80]", ra[0][:80])
    print("fused   [:80]", rb[0][:80])
