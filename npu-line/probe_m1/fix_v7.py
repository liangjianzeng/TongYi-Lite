# Fixer v7: replace Expand(x, shape) with Mul(x, ones(shape)) - avoids QAIRT Expand dtype validation entirely.
import onnx
from onnx import numpy_helper, TensorProto, helper
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512_fix7.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix8.onnx'

m = onnx.load(SRC, load_external_data=False)
g = m.graph
inits = {i.name: i for i in g.initializer}
dt = {}
for vi in list(g.value_info) + list(g.output) + list(g.input):
    dt[vi.name] = vi.type.tensor_type.elem_type

replaced = 0
new_nodes = []
pending = {}
for n in g.node:
    if n.op_type == 'Expand' and len(n.input) >= 2:
        x, shape_name = n.input[0], n.input[1]
        # resolve shape values
        shape_vals = None
        if shape_name in inits:
            shape_vals = numpy_helper.to_array(inits[shape_name]).astype(np.int64).tolist()
        else:
            # try constant producer
            for pn in g.node:
                if pn.op_type == 'Constant' and pn.output and pn.output[0] == shape_name:
                    for a in pn.attribute:
                        if a.name == 'value':
                            shape_vals = numpy_helper.to_array(a.t).astype(np.int64).tolist()
        if shape_vals is None:
            new_nodes.append(n); continue
        d0 = dt.get(x, TensorProto.FLOAT)
        npdt = {TensorProto.FLOAT16: np.float16, TensorProto.FLOAT: np.float32, TensorProto.INT32: np.int32}.get(d0, np.float16)
        ones_name = n.output[0].replace('/','_') + '_ones'
        ones_t = numpy_helper.from_array(np.ones(shape_vals, dtype=npdt), ones_name)
        g.initializer.append(ones_t)
        mul = helper.make_node('Mul', [x, ones_name], [n.output[0]], name=n.name + '_mul')
        new_nodes.append(mul)
        replaced += 1
    else:
        new_nodes.append(n)
del g.node[:]
g.node.extend(new_nodes)
print('Expands replaced with Mul:', replaced)
onnx.save_model(mi := m, DST, save_as_external_data=True, all_tensors_to_one_file=True, location='fix8.data', size_threshold=1024)
print('saved', DST)
