# Fixer v8: Expand->Mul with data-dtype-resolved ones (recursive dtype lookup).
import onnx
from onnx import numpy_helper, TensorProto, helper
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512_fix7.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix9.onnx'

m = onnx.load(SRC, load_external_data=False)
g = m.graph
inits = {i.name: i for i in g.initializer}
dt = {}
for vi in list(g.value_info) + list(g.output) + list(g.input):
    dt[vi.name] = vi.type.tensor_type.elem_type
prod = {}
for n in g.node:
    for o in n.output: prod[o] = n

def resolve_dtype(name, depth=0):
    if depth > 6: return None
    d = dt.get(name)
    if d: return d
    n = prod.get(name)
    if n is None: return None
    if n.op_type == 'Cast':
        for a in n.attribute:
            if a.name == 'to': return a.i
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.name == 'value': return a.t.data_type
    for inp in n.input:
        d = resolve_dtype(inp, depth+1)
        if d: return d
    return None

NPDT = {TensorProto.FLOAT16: np.float16, TensorProto.FLOAT: np.float32,
        TensorProto.INT32: np.int32, TensorProto.INT64: np.int64}

replaced = 0
dtfail = []
new_nodes = []
for n in g.node:
    if n.op_type == 'Expand' and len(n.input) >= 2:
        x, shape_name = n.input[0], n.input[1]
        shape_vals = None
        src = shape_name
        if src in inits:
            shape_vals = numpy_helper.to_array(inits[src]).astype(np.int64).tolist()
        else:
            pn = prod.get(src)
            if pn is not None and pn.op_type == 'Constant':
                for a in pn.attribute:
                    if a.name == 'value':
                        shape_vals = numpy_helper.to_array(a.t).astype(np.int64).tolist()
        if shape_vals is None:
            new_nodes.append(n); print('SKIP dynamic shape:', n.name); continue
        d0 = resolve_dtype(x)
        if d0 is None:
            dtfail.append(n.name); d0 = TensorProto.FLOAT16
        ones_name = n.output[0].replace('/','_') + '_ones_v8'
        g.initializer.append(numpy_helper.from_array(np.ones(shape_vals, dtype=NPDT[d0]), ones_name))
        new_nodes.append(helper.make_node('Mul', [x, ones_name], [n.output[0]], name=n.name + '_mul'))
        replaced += 1
    else:
        new_nodes.append(n)
del g.node[:]
g.node.extend(new_nodes)
print('replaced:', replaced, 'dtype-unresolved(f16 default):', dtfail)
onnx.save_model(m, DST, save_as_external_data=True, all_tensors_to_one_file=True, location='fix9.data', size_threshold=1024)
print('saved', DST)
