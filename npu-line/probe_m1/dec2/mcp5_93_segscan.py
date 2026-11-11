#!/usr/bin/env python3
# [npu-line] G3: auto-locate the int8 weight segments inside model.params.bin by
# |value|==127 density (quantized rows always contain +-127; fp16 constants don't).
# Then per-segment corr vs quantized HF weights in multiple layout interpretations.
import json
import zipfile
import numpy as np
import onnx
from onnx import numpy_helper

DLCZIP = '/home/liang/w4sim/ctx_w8nc640_l0/w8nc640_l0'
DJ = '/home/liang/w4sim/ctx_w8nc640_l0/dlcjson'
ONNX = '/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx'
ENC = json.load(open('/home/liang/l0_enc.json'))['param_encodings']

z = zipfile.ZipFile(DLCZIP)
inf = z.getinfo('model.params.bin'); fp = z.open(inf); fp._expected_crc = None
blob = np.frombuffer(fp.read(), np.uint8)
L = len(blob)
W = 256
dense = np.array([np.isin(blob[i:i+W], [1, 127, 128, 255]).mean() for i in range(0, L - W, W)])
hot = dense > 0.001  # int8 segments have measurable +-127 density
# merge runs
segs = []
st = None
for i, h in enumerate(hot):
    if h and st is None:
        st = i
    if not h and st is not None:
        segs.append((st * W, i * W)); st = None
if st is not None:
    segs.append((st * W, len(hot) * W))
print('segments found:', [(a, b, b - a) for a, b in segs])

d = json.load(open(DJ))['graph']
m = onnx.load(ONNX, load_external_data=True)
inits = {i.name: numpy_helper.to_array(i) for i in m.graph.initializer}
qts = sorted([(nm, t) for nm, t in d['tensors'].items() if t.get('data_type') == 776],
             key=lambda nt: nt[1]['id'])

def corr(a, b):
    a = a.ravel().astype(np.float64); b = b.ravel().astype(np.float64)
    if a.size != b.size or a.size == 0:
        return -9
    return float(np.corrcoef(a, b)[0, 1])

# expected quantized ints per tensor (onnx rhs IO [in,out] with own out-channel scales)
for nm, t in qts:
    base = nm.replace('_permute', '')
    sc = np.array([e['scale'] for e in ENC[base]], np.float32)
    Wf = inits[base].astype(np.float32)
    qexp = np.clip(np.round(Wf / sc[None, :]), -127, 127).astype(np.int8)  # [in,out]
    dims = t['dims']
    best = (-9, None)
    for a, b in segs:
        if b - a < np.prod(dims):
            continue
        raw = blob[a:a + np.prod(dims)].view(np.int8)
        for tag, q in (('C', raw.reshape(dims, order='C')),
                       ('F', raw.reshape(dims, order='F')),
                       ('C-ofT', raw.reshape(dims[::-1], order='C').T),
                       ('F-ofT', raw.reshape(dims[::-1], order='F').T)):
            c = corr(q.astype(np.float64), qexp.astype(np.float64))
            # also try vs OI-orientation expected (transposed HF weights quantized by rows)
            c2 = corr(q.astype(np.float64), qexp.T.astype(np.float64))
            for tt, cc in ((tag, c), (tag + '.T', c2)):
                if cc > best[0]:
                    best = (cc, (a, tt))
    print(f'{nm:28s} dims{str(dims):14s} bestcorr={best[0]:.4f} at {best[1]}')
