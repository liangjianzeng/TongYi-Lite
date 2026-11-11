#!/bin/bash
# [npu-line] G3: compare graph input/output registration ORDER + ids between the fp16
# control ctx and the w8 layer ctx (chain_run5 sets T.v2.id and array order from manifest).
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
for T in nc640_l0 w8nc640_l0 w8dec_l999head; do
  J=/tmp/cmpid_$T.json
  $SDK/bin/x86_64-linux-clang/qnn-context-binary-utility \
    --context_binary /mnt/e/MyLLM_exp/serve_dec/${T}_ctx.bin --json_file $J >/dev/null 2>&1
  echo "==== $T ===="
  python3 - "$J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))['info']['graphs'][0]['info']
print('graphName:', d['graphName'])
print('INS :', [(t['info']['name'], t['info']['id']) for t in d['graphInputs']])
print('OUTS:', [(t['info']['name'], t['info']['id']) for t in d['graphOutputs']])
PY
done
echo ==== MANIFEST ====
cat /mnt/e/MyLLM_exp/manifest_l0w8_w8nc640_l0
