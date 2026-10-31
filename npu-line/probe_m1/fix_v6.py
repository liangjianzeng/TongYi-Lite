# Fixer v6: QNN Expand-style same-dtype validation - cast param init to data dtype.
import onnx
from onnx import numpy_helper, TensorProto
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512_fix6.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix7.onnx'

m = onnx.load(SRC, load_external_data=False)
try:
    mi = onnx.shape_inference.infer_shapes(m, strict_mode=False, data_prop=True)
except Exception as ex:
    print('infer fail:', ex); mi = m
g = mi.graph
dt = {}
for vi in list(g.value_info) + list(g.output) + list(g.input):
    dt[vi.name] = vi.type.tensor_type.elem_type
inits = {i.name: i for i in g.initializer}

DTNAME = {1:'f32',10:'f16',6:'i32',7:'i64'}
rewritten = 0
casted = 0
new_nodes = []
pending = {}
for n in g.node:
    if n.op_type == 'Expand' and len(n.input) >= 2:
        d0 = dt.get(n.input[0]); d1 = dt.get(n.input[1])
        if d1 is None and n.input[1] in inits:
            d1 = inits[n.input[1]].data_type
        if d0 and d1 and d0 != d1:
            if n.input[1] in inits:
                arr = numpy_helper.to_array(inits[n.input[1]])
                t = numpy_helper.from_array(arr.astype(np.float16 if d0==10 else np.float32), n.input[1])
                for k, existing in enumerate(g.initializer):
                    if existing.name == n.input[1]:
                        g.initializer[k].CopyFrom(t)
                        break
                rewritten += 1
            else:
                co = n.input[1] + '_dcast'
                new_nodes.append(helper.make_node('Cast', [n.input[1]], [co], name=co.replace('/','_')+'_c', to=d0))
                n.input[1] = co
                pending[co] = True
                casted += 1
    # register casts before consumers
    for inp in n.input:
        if inp in pending:
            pass
for n in g.node:
    pass
# insert pending casts right before consumers: rebuild
if pending:
    plist = list(pending.items())
    new_nodes2 = []
    made = {co: helper.make_node('Cast', [co_src], [co], name=co.replace('/','_')+'_c', to=10) for co, co_src in []}
    # simpler: we already appended cast nodes to new_nodes list; place them before first consumer
    place = {}
    for co, node in [(c.output[0], c) for c in new_nodes]:
        for n in g.node:
            if co in n.input:
                place.setdefault(id(n), []).append(node)
    newlist = []
    done = set()
    for n in g.node:
        for node in place.get(id(n), []):
            if id(node) not in done:
                newlist.append(node); done.add(id(node))
        newlist.append(n)
    del g.node[:]
    g.node.extend(newlist)
print('inits rewritten:', rewritten, 'casts:', casted)
onnx.save_model(mi, DST, save_as_external_data=True, all_tensors_to_one_file=True, location='fix7.data', size_threshold=1024)
print('saved', DST)
