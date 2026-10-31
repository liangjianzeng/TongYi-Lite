# Fixer v5: harmonize integer helper tensor dtypes - insert Cast(int64->int32) on param edges.
import onnx
from onnx import numpy_helper, TensorProto, helper
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512_fix5.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix6.onnx'

m = onnx.load(SRC, load_external_data=False)
try:
    mi = onnx.shape_inference.infer_shapes(m, strict_mode=False, data_prop=True)
except Exception as ex:
    print('infer fail:', ex); mi = m
g = mi.graph

dtype_of = {}
for vi in list(g.value_info) + list(g.output) + list(g.input):
    tt = vi.type.tensor_type
    dtype_of[vi.name] = tt.elem_type

PARAM_EDGES = {'Expand': [1], 'Reshape': [1], 'Pad': [1,2,3], 'Squeeze': [1], 'Unsqueeze': [1], 'ReduceMean': [1], 'ReduceSum': [1], 'ReduceMax': [1], 'ReduceMin': [1]}

casts = []
count = 0
for n in g.node:
    if n.op_type not in PARAM_EDGES:
        continue
    for idx in PARAM_EDGES[n.op_type]:
        if idx >= len(n.input): continue
        inp = n.input[idx]
        dt = dtype_of.get(inp)
        if dt == TensorProto.INT64:
            cast_out = inp + '_i32cast'
            casts.append(helper.make_node('Cast', [inp], [cast_out], name=cast_out.replace('/','_'), to=TensorProto.INT32))
            n.input[idx] = cast_out
            dtype_of[cast_out] = TensorProto.INT32
            count += 1
print('casts inserted:', count)

if casts:
    # topologically safe: constants producers come earlier; put casts before consumers is hard post-hoc.
    # Instead rebuild node list: place each cast immediately before its consumer.
    new_nodes = []
    pending = {c.output[0]: c for c in casts}
    consumer_of = {}
    for n in g.node:
        for inp in n.input:
            if inp in pending:
                new_nodes.append(pending[inp])
                del pending[inp]
        new_nodes.append(n)
    for c in casts:  # any remaining (shouldn't)
        if c.output[0] in pending:
            new_nodes.append(pending[c.output[0]])
    del g.node[:]
    g.node.extend(new_nodes)

onnx.save_model(mi, DST, save_as_external_data=True, all_tensors_to_one_file=True, location='fix6.data', size_threshold=1024)
print('saved', DST)
