#!/bin/bash
# [npu-line] G3: op+tensor census for w8none_l0 (wrapper-fp16 control) DLC vs w8nc640_l0.
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
export PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang
OUT=/home/liang/w4sim/ctx_w8none_l0
if [ ! -f $OUT/dlcjson ]; then
  $SDK/bin/x86_64-linux-clang/qairt-dlc-to-json -i $OUT/w8none_l0 -o $OUT/dlcjson
fi
python3 - <<'PY'
import json, collections
for tag in ['w8none_l0', 'w8nc640_l0']:
    d = json.load(open(f'/home/liang/w4sim/ctx_{tag}/dlcjson'))['graph']
    cnt = collections.Counter(n['type'] for n in d['nodes'].values())
    q = collections.Counter(t.get('data_type') for t in d['tensors'].values())
    n_fc = sum(1 for n in d['nodes'].values() if n['type'] == 'FullyConnected')
    print(tag, 'nodes', len(d['nodes']), 'tensors', len(d['tensors']))
    print('  census', dict(cnt))
    print('  dtypes', dict(q))
PY
