#!/usr/bin/env python3
# [npu-line] G3: structural look at the w8 DLC json — op-type census vs fp16 expectations,
# amask consumer chain (is the -1e4 mask const still -1e4? or requantized to 0?),
# rope constants, cache concat. Any structural rewrite by the quantizer shows here.
import json
import collections
import sys

DJ = sys.argv[1] if len(sys.argv) > 1 else '/home/liang/w4sim/ctx_w8nc640_l0/dlcjson'
d = json.load(open(DJ))['graph']
ops = [n['op'] if isinstance(n, dict) else None for n in d['operations']]
# operations entries: {'name':..., 'type':...} — census:
cnt = collections.Counter()
for o in d['operations']:
    cnt[o.get('type', o.get('op_type', '?'))] += 1
print('OP CENSUS:', dict(cnt))

tens = d['tensors']
# amask consumer chain: walk from graph input amask
def consumers_of(name):
    out = []
    for o in d['operations']:
        if name in (o.get('inputs') or []):
            out.append((o.get('name'), o.get('type')))
    return out

def producers_of(name):
    out = []
    for o in d['operations']:
        if name in (o.get('outputs') or []):
            out.append((o.get('name'), o.get('type')))
    return out

# find amask-ish tensor names
am = [n for n in tens if 'mask' in n.lower() or 'am' in n.lower()[:3]]
print('mask-ish tensors:', am[:10])
for n in am[:4]:
    print(' ', n, 'type', tens[n].get('data_type'), 'dims', tens[n].get('dims'),
          'consumers', consumers_of(n)[:4])
# small fp16 constants (<=641 elems) — candidates for the -1e4 mask const
print('--- small fp16 consts with big |value| ---')
for n, t in tens.items():
    if t.get('type') not in (4, 'TENSOR_TYPE_PARAMETER'):
        continue
    if t.get('data_type') not in (562, 'DT_FLOAT_16'):
        continue
    dims = t.get('dims') or []
    sz = 1
    for x in dims:
        sz *= x
    if sz and sz <= 2048:
        # peek quant_params absent => raw fp16; can't see values from json dump
        pass
# rope-ish
rp = [n for n in tens if 'cos' in n.lower() or 'sin' in n.lower() or 'rope' in n.lower()]
print('rope-ish tensors:', rp[:12])
for n in rp[:6]:
    print(' ', n, 'type', tens[n].get('data_type'), tens[n].get('dims'), 'consumers', consumers_of(n)[:3])
