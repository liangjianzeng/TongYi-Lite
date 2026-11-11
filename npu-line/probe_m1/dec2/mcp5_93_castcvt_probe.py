#!/usr/bin/env python3
# [npu-line] G3: does the quantizer's attention-path rewrite (Cast _to_copy_2/_to_copy_3
# on rope-add & softmax + Convert on the attention-scale scalar) appear in EVERY red
# variant and NEVER in the green head? reads ctx_<tag>/dlcjson (generate first if absent).
import json
import os
import subprocess
import sys

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
TAGS = sys.argv[1:] or ["w8none_l0", "w8offfc_nfx_l0", "w8nc640_l0", "w8dec_l999head"]

for tag in TAGS:
    d = "/home/liang/w4sim/ctx_%s" % tag
    dj = d + "/dlcjson"
    if not os.path.exists(dj):
        r = subprocess.run([SDK + "/bin/x86_64-linux-clang/qairt-dlc-to-json", "-i",
                            d + "/" + tag, "-o", dj], capture_output=True,
                           env={**os.environ, "PYTHONPATH": SDK + "/lib/python",
                                "LD_LIBRARY_PATH": SDK + "/lib/x86_64-linux-clang"})
        if r.returncode != 0:
            print(tag, "DLC2JSON_FAIL rc=%d (DLC dir gone?)" % r.returncode)
            continue
    g = json.load(open(dj))["graph"]
    nodes = g["nodes"]
    casts = [(n, tuple(o for o in (v.get("input_names") or []))) for n, v in nodes.items()
             if v.get("type") == "Cast"]
    convs = [(n, tuple(o for o in (v.get("input_names") or []))) for n, v in nodes.items()
             if v.get("type") == "Convert"]
    tc = [n for n in nodes if "_to_copy" in n]
    mm = sum(1 for v in nodes.values() if v.get("type") == "MatMul")
    fc = sum(1 for v in nodes.values() if v.get("type") == "FullyConnected")
    print("==", tag, "MatMul=%d FC=%d Cast=%d Convert=%d" % (mm, fc, len(casts), len(convs)))
    for n, ins in casts[:6]:
        print("    Cast", n, ins)
    for n, ins in convs[:6]:
        print("    Conv", n, ins)
    print("    _to_copy nodes:", sorted(set(t.split(".")[0] for t in tc))[:12])
print("CASTCVT_DONE")
