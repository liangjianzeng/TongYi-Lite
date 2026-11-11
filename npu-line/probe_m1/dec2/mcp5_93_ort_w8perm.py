#!/usr/bin/env python3
# [npu-line] G3 H_POOL: within equal-scale-count groups the ctxgen/HTP packer could
# rotate the per-channel scale arrays (count checks can't catch it): {val_6, o_proj,
# val_115} all have 2048 scales, {val_13,val_20} 256, {val_112,val_114} 6144. val_112
# carries the 1e-8 clamp scale -> landing on another tensor's rows = 1e5x blow-up
# = fp16 saturation/NaN, exactly the device raws (h 66% NaN, kn max 48960).
# Quant bytes stay correct (converter quantized with own scale); only DEQUANT scale
# is swapped. Compare vs device p_{h,kn,vn}.raw incl. NaN-position agreement.
import json
import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper

ONNX0 = '/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx'
ENC = json.load(open('/home/liang/l0_enc.json'))['param_encodings']
ST = '/mnt/e/wsl_stage'

m0 = onnx.load(ONNX0, load_external_data=True)
inits = {i.name: numpy_helper.to_array(i) for i in m0.graph.initializer}

def feed(name, a):
    inp = [i for i in m0.graph.input if i.name == name][0]
    dims = [d.dim_value if d.HasField('dim_value') else 1
            for d in inp.type.tensor_type.shape.dim]
    return np.asarray(a, np.float16).reshape(dims)

F = {'hs': feed('hs', np.fromfile(f'{ST}/d2e_hs0.raw', '<f2')),
     'kcache': feed('kcache', np.fromfile(f'{ST}/d2e640b_kc0.raw', '<f2')),
     'vcache': feed('vcache', np.fromfile(f'{ST}/d2e640b_vc0.raw', '<f2')),
     'cos': feed('cos', np.fromfile(f'{ST}/d2_cos_table.raw', '<f2')[:128]),
     'sin': feed('sin', np.fromfile(f'{ST}/d2_sin_table.raw', '<f2')[:128]),
     'amask': feed('amask', np.fromfile(f'{ST}/g_am640_t0.raw', '<f2'))}

DEV = {'h': np.fromfile(f'{ST}/dev/p_h.raw', '<f2').astype(np.float32).ravel(),
       'kn': np.fromfile(f'{ST}/dev/p_kn.raw', '<f2').astype(np.float32).ravel(),
       'vn': np.fromfile(f'{ST}/dev/p_vn.raw', '<f2').astype(np.float32).ravel()}

def score(a, b):
    na, nb = np.isnan(a), np.isnan(b)
    nanagree = float((na == nb).mean())
    fin = np.isfinite(a) & np.isfinite(b)
    if fin.sum() < 10:
        return nanagree, float('nan'), int(nanagree * len(a) - (na & nb).sum())
    c = float(np.dot(a[fin], b[fin]) / (np.linalg.norm(a[fin]) * np.linalg.norm(b[fin]) + 1e-30))
    mism = int((na ^ nb).sum())
    return nanagree, c, mism

def variant(scalemap, tag):
    m = onnx.load(ONNX0, load_external_data=True)
    imap = {i.name: i for i in m.graph.initializer}
    for name in ENC:
        sc_own = np.array([e['scale'] for e in ENC[name]], np.float32)
        sc_use = np.array([e['scale'] for e in ENC[scalemap.get(name, name)]], np.float32)
        init = imap.get(name) or imap[[k for k in imap if k.startswith(name)][0]]
        W = numpy_helper.to_array(init).astype(np.float32)  # [in,out]
        q = np.clip(np.round(W / sc_own[None, :]), -127, 127)
        Wd = q * sc_use[None, :]
        m.graph.initializer.remove(init)
        m.graph.initializer.append(numpy_helper.from_array(Wd.astype(np.float16), name=init.name))
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sess = ort.InferenceSession(m.SerializeToString(), so, providers=['CPUExecutionProvider'])
    outs = sess.run(None, F)
    line = f'{tag:26s}'
    for nm, o in zip(['h', 'kn', 'vn'], outs):
        a = np.asarray(o, np.float32).ravel()
        agree, c, mism = score(a, DEV[nm])
        line += f'  {nm}: agree={agree:.3f} cos={c:.4f} mism={mism}'
    print(line, flush=True)

ID = {k: k for k in ENC}
variant(ID, 'P0 control')
variant({'val_13': 'val_20', 'val_20': 'val_13'}, 'P1 swap kv')
variant({'val_6': 'attn.o_proj.weight', 'attn.o_proj.weight': 'val_115',
         'val_115': 'val_6'}, 'P2 rot 2048grp a')
variant({'val_6': 'val_115', 'val_115': 'attn.o_proj.weight',
         'attn.o_proj.weight': 'val_6'}, 'P3 rot 2048grp b')
variant({'val_112': 'val_114', 'val_114': 'val_112'}, 'P4 swap gate/up')
P5 = {'val_13': 'val_20', 'val_20': 'val_13', 'val_112': 'val_114', 'val_114': 'val_112',
      'val_6': 'attn.o_proj.weight', 'attn.o_proj.weight': 'val_115', 'val_115': 'val_6'}
variant(P5, 'P5 all swapped')
# P6: every FC dequantized with val_112's scale array (the 1e-8-clamp one)
variant({k: 'val_112' for k in ENC if k != 'val_114' and len(ENC[k]) == len(ENC['val_112'])},
        'P6 gate-scales everywhere6144')
