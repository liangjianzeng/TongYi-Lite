#!/usr/bin/env python3
# [npu-line] G3: host forensics on pulled per-tag probe raws. For each w8 build's
# p_kn/p_vn, test cos against ORT reference vectors AND against each other (is k_raw
# really v? is it pre-rope k? hs? a cache slice?).
import json
import numpy as np
import onnx
import onnxruntime as ort

ONNX0 = '/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx'
ST = '/mnt/e/wsl_stage'
TAGS = ['w8nc640_l0', 'w8abq2_l0', 'w8abk2_l0', 'w8abg2_l0', 'w8attn_l0', 'w8mlp_l0']

m = onnx.load(ONNX0, load_external_data=True)
mi = {i.name: [d.dim_value for d in i.type.tensor_type.shape.dim] for i in m.graph.input}

def feed(name, a):
    return np.asarray(a, '<f2').reshape(mi[name])

F = {'hs': feed('hs', np.fromfile(f'{ST}/d2e_hs0.raw', '<f2')),
     'kcache': feed('kcache', np.fromfile(f'{ST}/d2e640b_kc0.raw', '<f2')),
     'vcache': feed('vcache', np.fromfile(f'{ST}/d2e640b_vc0.raw', '<f2')),
     'cos': feed('cos', np.fromfile(f'{ST}/d2_cos_table.raw', '<f2')[:128]),
     'sin': feed('sin', np.fromfile(f'{ST}/d2_sin_table.raw', '<f2')[:128]),
     'amask': feed('amask', np.fromfile(f'{ST}/g_am640_t0.raw', '<f2'))}

so = ort.SessionOptions()
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
sess = ort.InferenceSession(m.SerializeToString(), so, providers=['CPUExecutionProvider'])
allnames = [o.name for o in sess.get_outputs()]
# fetch everything to probe intermediate vectors
want = ['h', 'knew', 'vnew']
refs = dict(zip(want, sess.run(want, F)))

# pre-rope k: recompute k_proj(x_postln) — get via subgraph? cheaper: grab all sess outputs
outs = sess.run(allnames, F)
byname = dict(zip(allnames, outs))

def cos(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    n = min(len(a), len(b))
    if n == 0 or (not np.all(np.isfinite(a[:n]))):
        return float('nan')
    return float(a[:n] @ b[:n] / (np.linalg.norm(a[:n]) * np.linalg.norm(b[:n]) + 1e-30))

hs = F['hs'].astype(np.float32).ravel()
kc = F['kcache'].astype(np.float32).ravel()

for tag in TAGS:
    try:
        kn = np.fromfile(f'{ST}/dev/p_{tag}_kn.raw', '<f2').astype(np.float32)
        vn = np.fromfile(f'{ST}/dev/p_{tag}_vn.raw', '<f2').astype(np.float32)
    except FileNotFoundError:
        print(tag, 'NO RAW'); continue
    cands = {'ref_knew': refs['knew'], 'ref_vnew': refs['vnew'], 'hs': hs,
             'kc_lastrow': kc[-128:]}
    for nm, mid in byname.items():
        arr = np.asarray(mid)
        if arr.size == 256:
            cands['mid:' + nm[:28]] = arr
    ks = '  '.join(f'{nm}={cos(kn, v):.3f}' for nm, v in cands.items())
    print(f'{tag} kn: {ks}')
    print(f'{tag} kn_vs_vn = {cos(kn, vn):.3f}')
