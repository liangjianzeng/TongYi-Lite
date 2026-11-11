#!/bin/bash
# [npu-line] G3: census the GREEN fp16 nc640_l0 DLC (mcp5_92 line) as the structural baseline.
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
export PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang
D=/home/liang/w4sim/ctx_nc640_l0
[ -f $D/dlcjson ] || $SDK/bin/x86_64-linux-clang/qairt-dlc-to-json -i $D/nc640_l0 -o $D/dlcjson
python3 - <<'PY'
import json, collections
d = json.load(open('/home/liang/w4sim/ctx_nc640_l0/dlcjson'))['graph']
cnt = collections.Counter(n['type'] for n in d['nodes'].values())
q = collections.Counter(t.get('data_type') for t in d['tensors'].values())
print('nc640_l0 (GREEN fp16) nodes', len(d['nodes']), 'tensors', len(d['tensors']))
print(' census', dict(cnt))
print(' dtypes', dict(q))
PY
