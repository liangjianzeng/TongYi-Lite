#!/bin/bash
# [npu-line] dump graph name + tensor ids of ctx binaries; args = ctx file paths (WSL paths)
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
export LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang
for f in "$@"; do
  b=$(basename "$f" _ctx.bin)
  $SDK/bin/x86_64-linux-clang/qnn-context-binary-utility --context_binary "$f" --json_file /tmp/dump_$b.json >/dev/null 2>&1
  python3 - "$b" <<'PY'
import json, sys
b = sys.argv[1]
d = json.load(open(f"/tmp/dump_{b}.json"))["info"]["graphs"][0]["info"]
print(b, "graph", d["graphName"])
for k in ("graphInputs", "graphOutputs"):
    for t in d[k]:
        i = t["info"]
        print("  ", k[-4:], i["name"], i["id"], i["dataType"], i["dimensions"])
PY
done
