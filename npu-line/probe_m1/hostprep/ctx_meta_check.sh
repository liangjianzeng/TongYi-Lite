#!/bin/bash
# QA: dump metadata of both host-prepared ctx binaries and summarize key fields.
set -e
SDK=/mnt/d/MyLLM/qairt/2.44.0.260225
U=$SDK/bin/x86_64-linux-clang/qnn-context-binary-utility
export LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang
for pair in "/mnt/e/MyLLM_exp/r2ctx/spark_r2_ctx.bin:/mnt/e/MyLLM_exp/_repro/ctx_v73_meta.json" \
            "/mnt/e/MyLLM_exp/r2ctx_v79/spark_r2_v79_ctx.bin:/mnt/e/MyLLM_exp/_repro/ctx_v79_meta.json"; do
  BIN=${pair%%:*}; JSON=${pair##*:}
  "$U" --context_binary "$BIN" --json_file "$JSON" > /dev/null 2>&1
  python3 - "$JSON" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))
print("FILE", sys.argv[1])
print(" version:", d.get("version"))
print(" backendCounter:", d.get("backendCounter"), " SoC/Platform keys:",
      {k:d[k] for k in d if "soc" in k.lower() or "platform" in k.lower() or "backend" in k.lower()})
for g in d.get("graphNames", d.get("graphs", []))[:1] if isinstance(d.get("graphNames", d.get("graphs", [])), list) else []:
    print(" graph:", g if isinstance(g,str) else g.get("graphName"))
    if not isinstance(g,str):
        for t in g.get("inputTensors", [])[:3]: print("   IN :", t.get("name"), t.get("dims"), t.get("dataType"))
        for t in g.get("outputTensors", [])[:3]: print("   OUT:", t.get("name"), t.get("dims"), t.get("dataType"))
print(" top-level keys:", sorted(d.keys()))
EOF
done
echo CTX_META_CHECK_DONE
