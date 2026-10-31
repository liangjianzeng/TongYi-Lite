import onnx
from onnx import numpy_helper
m = onnx.load(r'E:/MyLLM_exp/spark_prefill_seq512_fix6.onnx', load_external_data=False)
g = m.graph
inits = {i.name: i for i in g.initializer}
prod = {}
for n in g.node:
    for o in n.output: prod[o] = n
dt = {}
for vi in list(g.value_info) + list(g.output) + list(g.input):
    dt[vi.name] = vi.type.tensor_type.elem_type

t = [n for n in g.node if n.name == 'node_expand_5']
for n in t:
    print('node:', n.name, n.op_type, n.input, '->', n.output)
    for inp in n.input:
        print('  in:', inp, 'dtype=', dt.get(inp), 'init=', (numpy_helper.to_array(inits[inp]).tolist()[:6] if inp in inits else '-'),
              'prod=', (prod[inp].op_type+':'+prod[inp].name if inp in prod else 'graph-input'))
# list dtypes of graph inputs
for gi in g.input:
    print('graph input:', gi.name, gi.type.tensor_type.elem_type)
# count int64 value_info tensors
import collections
cnt = collections.Counter(v for v in dt.values())
print('dtype histogram:', dict(cnt), '(1=f32,7=i64,6=i32,10=f16)')
# show a few int64 tensors with producers
shown = 0
for name, d in dt.items():
    if d == 7 and shown < 12:
        p = prod.get(name)
        print('i64 tensor:', name, 'prod=', (p.op_type+':'+p.name if p else 'input'))
        shown += 1
