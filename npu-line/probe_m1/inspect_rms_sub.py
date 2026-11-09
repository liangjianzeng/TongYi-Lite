import onnx, numpy as np
from onnx import numpy_helper
m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v4.onnx', load_external_data=False)
g = m.graph
dt = {}
def reg(name, etype):
    dt[name] = etype
for vi in list(g.input)+list(g.output)+list(g.value_info):
    reg(vi.name, vi.type.tensor_type.elem_type)
const_t = {}
for init in g.initializer:
    reg(init.name, init.data_type)
    const_t[init.name] = init
const_nodes = {}
for n in g.node:
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.name == 'value':
                reg(n.output[0], a.t.data_type)
                const_t[n.output[0]] = a.t
DT={1:'f32',6:'i32',7:'i64',9:'bool',10:'f16'}
# find layer0 rms: locate first Pow whose input is graph-wide... easier: find ReduceMean nodes and walk back 4 hops
# find nodes named with Mul_1
import collections
# print all Constant node value dtypes histogram
cdt = collections.Counter()
for name, t in const_t.items():
    cdt[t.data_type] += 1
print('ALL_CONST_DT', dict(cdt))
# find the fused pattern: nodes producing 'rms_norm' name won't exist in onnx; instead find ReduceMean -> Add(eps) chains
# strategy: find node that consumes a Constant eps (scalar f32?) via Add
eps_consts = [(nm, t) for nm, t in const_t.items() if t.data_type == 1]
print('f32 consts:', len(eps_consts))
for nm, t in eps_consts[:15]:
    arr = numpy_helper.to_array(t)
    print('  f32const', nm, arr.shape, arr.ravel()[:4])
# find Add nodes consuming any f32 const
consumers = collections.defaultdict(list)
for n in g.node:
    for i in n.input:
        consumers[i].append(n)
for nm, t in eps_consts[:10]:
    for n in consumers.get(nm, []):
        print('CONSUMER of', nm, ':', n.op_type, n.name, [i for i in n.input])
