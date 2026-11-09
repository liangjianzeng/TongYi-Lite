# v3 -> v4: replace Div(scalar_const_1.0, y) with Reciprocal(y).
# External data is NOT loaded; external refs are preserved on save (same dir).
import onnx
from onnx import numpy_helper, TensorProto
SRC='/mnt/e/MyLLM_exp/spark_prefill_v3.onnx'
DST='/mnt/e/MyLLM_exp/spark_prefill_v4.onnx'
m = onnx.load(SRC, load_external_data=False)
g = m.graph
const_out = {}
for n in g.node:
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.name == 'value':
                const_out[n.output[0]] = a.t
for init in g.initializer:
    const_out[init.name] = init

new_nodes = []
replaced = 0
removed_consts = set()
for n in g.node:
    if n.op_type == 'Div' and n.input[0] in const_out:
        t = numpy_helper.to_array(const_out[n.input[0]])
        if t.size == 1 and float(t.ravel()[0]) == 1.0:
            new_nodes.append(onnx.helper.make_node('Reciprocal', [n.input[1]], list(n.output), name=n.name + '_recip'))
            replaced += 1
            continue
    if n.op_type == 'Constant' and n.output[0] in const_out:
        # keep; may be used by others
        pass
    new_nodes.append(n)
del g.node[:]
g.node.extend(new_nodes)
print('replaced', replaced)
onnx.checker.check_model(m, False)
onnx.save(m, DST)
print('saved', DST)
# verify reload
m2 = onnx.load(DST, load_external_data=False)
ops = {}
for n in m2.graph.node:
    ops[n.op_type] = ops.get(n.op_type,0)+1
print('v4 ops Div=', ops.get('Div'), 'Reciprocal=', ops.get('Reciprocal'))
