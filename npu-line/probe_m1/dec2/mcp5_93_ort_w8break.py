#!/usr/bin/env python3
# [npu-line] G3 discriminator: simulate the 'FIXUP5 stale-bytes' hypothesis on host ORT.
# HTP FC declared OI [out,in]: y = x @ Wdecl^T, dequant by axis0 (per-out) scale.
# If quantizer packed bytes from the PRE-transpose IO array (stale), the device
# effectively uses qview = reshape(qio.ravel(), (out,in)); rhs_eff = (qview*sc)^T.
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
names = {i.name for i in m0.graph.input}

def feed(name, a):
    from onnxruntime import NodeArg
    inp = [i for i in m0.graph.input if i.name == name][0]
    dims = [d.dim_value if d.HasField('dim_value') else 1
            for d in inp.type.tensor_type.shape.dim]
    a = np.asarray(a, np.float16).reshape(dims)
    return a

F = {'hs': feed('hs', np.fromfile(f'{ST}/d2e_hs0.raw', '<f2')),
     'kcache': feed('kcache', np.fromfile(f'{ST}/d2e640b_kc0.raw', '<f2')),
     'vcache': feed('vcache', np.fromfile(f'{ST}/d2e640b_vc0.raw', '<f2')),
     'cos': feed('cos', np.fromfile(f'{ST}/d2_cos_table.raw', '<f2')[:128]),
     'sin': feed('sin', np.fromfile(f'{ST}/d2_sin_table.raw', '<f2')[:128]),
     'amask': feed('amask', np.fromfile(f'{ST}/g_am640_t0.raw', '<f2'))}

DEV = {'h': np.fromfile(f'{ST}/dev/p_h.raw', '<f2').astype(np.float32).ravel(),
       'knew': np.fromfile(f'{ST}/dev/p_kn.raw', '<f2').astype(np.float32).ravel(),
       'vnew': np.fromfile(f'{ST}/dev/p_vn.raw', '<f2').astype(np.float32).ravel()}

def cos(a, b):
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30))

def run(model, tag):
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sess = ort.InferenceSession(model.SerializeToString(), so,
                                providers=['CPUExecutionProvider'])
    outs = sess.run(None, F)
    r = {}
    for nm, o in zip(['h', 'knew', 'vnew'], outs):
        r[nm] = cos(np.asarray(o).astype(np.float32).ravel(), DEV[nm])
    print(f'{tag:22s} ' + '  '.join(f'{k}={v:.4f}' for k, v in r.items()))

def variant(mode):
    m = onnx.load(ONNX0, load_external_data=True)
    imap = {i.name: i for i in m.graph.initializer}
    for name, encs in ENC.items():
        sc = np.array([e['scale'] for e in encs], np.float32)
        init = imap.get(name)
        if init is None:
            # o_proj key may carry a suffix in onnx?
            cand = [k for k in imap if k.startswith(name)]
            init = imap[cand[0]]
        W = numpy_helper.to_array(init).astype(np.float32)  # onnx rhs = [in,out]
        qio = np.clip(np.round(W / sc[None, :]), -127, 127)  # per-out-col scale
        if mode == 'clean':
            Wd = W
        elif mode == 'w8ok':
            Wd = qio * sc[None, :]
        elif mode == 'stale':
            qv = qio.reshape(-1).reshape(W.shape[1], W.shape[0])  # IO bytes seen as OI
            Wd = (qv * sc[:, None]).T
        new = numpy_helper.from_array(Wd.astype(np.float16), name=init.name)
        m.graph.initializer.remove(init)
        m.graph.initializer.append(new)
    return m

run(variant('clean'), 'V_CLEAN(fp16)')
run(variant('w8ok'), 'V_W8OK(correct qdq)')
run(variant('stale'), 'V_STALE(io bytes as OI)')
# partial: stale only non-square weights
def variant_partial():
    m = onnx.load(ONNX0, load_external_data=True)
    imap = {i.name: i for i in m.graph.initializer}
    for name, encs in ENC.items():
        sc = np.array([e['scale'] for e in encs], np.float32)
        init = imap.get(name) or imap[[k for k in imap if k.startswith(name)][0]]
        W = numpy_helper.to_array(init).astype(np.float32)
        if W.shape[0] == W.shape[1]:
            continue
        qio = np.clip(np.round(W / sc[None, :]), -127, 127)
        qv = qio.reshape(-1).reshape(W.shape[1], W.shape[0])
        Wd = (qv * sc[:, None]).T
        m.graph.initializer.remove(init)
        m.graph.initializer.append(numpy_helper.from_array(Wd.astype(np.float16), name=init.name))
    return m
run(variant_partial(), 'V_STALE(nonsquare only)')
