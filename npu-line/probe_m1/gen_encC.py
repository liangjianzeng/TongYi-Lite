# -*- coding: utf-8 -*-
# [C32] Plan C: W4-quantize the two fp16 mega-tensors (embedding 640M, lm_head 671M)
# to fit the model-lib blob under the 4GiB link range. Same per-channel symmetric format
# as the 217 proven weight entries.
import json, re
SRC = '/mnt/e/MyLLM_exp/spark_w4_enc.json'
DST = '/mnt/e/MyLLM_exp/spark_w4_encC.json'
import numpy as np, onnx

m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v4w32.onnx', load_external_data=False)
inits = {i.name: i for i in m.graph.initializer}

def per_channel_entries(name, kdim):
    # read raw fp32 from external file via onnx (external data resolved relative to model dir)
    import os
    t = inits[name]
    if t.data_location == onnx.TensorProto.EXTERNAL:
        kv = {e.key: e.value for e in t.external_data}
        path = os.path.join('/mnt/e/MyLLM_exp', kv['location'])
        off = int(kv.get('offset', 0))
        ln = int(kv.get('length', os.path.getsize(path) - off))
        with open(path, 'rb') as fh:
            fh.seek(off)
            loc = fh.read(ln)
    else:
        loc = t.raw_data
    dt = {onnx.TensorProto.FLOAT: '<f4', onnx.TensorProto.FLOAT16: '<f2'}[t.data_type]
    W = np.frombuffer(loc, dtype=dt)
    K, N = t.dims[kdim - 1], None
    dims = tuple(t.dims)
    # per OUTPUT-channel: for MatMul B [K,N] quantize along K -> N scales; embedding [V,H] -> V scales
    W = W.reshape(dims)
    if name.startswith('m.model.embedding'):
        A = W  # [V,H], per row (V)
    else:
        A = W.T if W.shape[0] != 131072 else W  # lm_head stored [2560,131072] -> per col = 131072
        A = W.T  # -> [131072,2560]: per row
    entries = []
    for r in range(A.shape[0]):
        mv = float(np.abs(A[r]).max())
        s = mv / 7.0 if mv > 0 else 1e-8
        entries.append({"min": -mv, "max": mv, "scale": s, "offset": 7,
                        "bitwidth": 4, "is_symmetric": "true"})
    return entries

d = json.load(open(SRC))
pe = d['param_encodings']
for name in ['m.model.embedding.weight', 'onnx::MatMul_7562']:
    ent = per_channel_entries(name, 1)
    pe[name] = ent
    print('added', name, len(ent), 'entries')
json.dump(d, open(DST, 'w'))
print('ENCC_OK total', len(pe))
