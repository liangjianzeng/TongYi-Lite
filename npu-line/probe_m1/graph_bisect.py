import os
import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto

BASE = '/mnt/e/MyLLM_exp'
OUT = BASE + '/_repro'
m = onnx.load(BASE + '/spark_prefill_v4.onnx', load_external_data=False)
g = m.graph

nodes = list(g.node)
N = len(nodes)
print('total nodes', N, flush=True)

# find layer boundary indices
import re
bounds = {}
for idx, n in enumerate(nodes):
    for i in n.input:
        mm = re.search(r'm\.model\.layers\.(\d+)\.', i)
        if mm:
            lay = int(mm.group(1))
            if lay not in bounds:
                bounds[lay] = idx
    for o in n.output:
        mm = re.search(r'layers\.(\d+)\.', o)
        if mm:
            lay = int(mm.group(1))
            if lay not in bounds:
                bounds[lay] = idx
print('layer first-node idx:', sorted(bounds.items())[:8], '...', flush=True)

prod = {}
for idx, n in enumerate(nodes):
    for o in n.output:
        prod[o] = idx

orig_out_names = [o.name for o in g.output]
orig_out_map = {o.name: o for o in g.output}

def build_prefix(K, tag):
    sub = nodes[:K]
    sub_outs = set()
    for n in sub:
        sub_outs.update(n.output)
    outs = []
    for nm in orig_out_names:
        if nm in sub_outs:
            outs.append(orig_out_map[nm])
    if not outs:
        # declare outputs of the last node fp16 guessed shape
        last = sub[-1]
        for o in last.output:
            outs.append(helper.make_tensor_value_info(o, TensorProto.FLOAT16, [1, 512, 2560]))
    ng = onnx.GraphProto if False else None
    graph = helper.make_graph(sub, 'pfx_%s' % tag, list(g.input), outs, list(g.initializer))
    mm2 = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    mm2.ir_version = 8
    p = os.path.join(BASE, '_pfx_%s.onnx' % tag)
    onnx.save(mm2, p)
    return p

# coarse ladder: embedding+L0 (idx of layers.1), then every 8 layers, then full-ish
cuts = []
if 1 in bounds: cuts.append(bounds[1])
for lay in range(8, 37, 8):
    if lay in bounds: cuts.append(bounds[lay])
cuts.append(N)
print('cut points:', cuts, flush=True)
for K in cuts:
    p = build_prefix(K, str(K))
    print('built', p, flush=True)
