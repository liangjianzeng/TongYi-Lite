# Fixer v4: per-slice int32 params (resolve INT64_MAX per-use), global int64->int32 sweep, NO removals.
import onnx
from onnx import numpy_helper, TensorProto
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512_fix3.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix5.onnx'

m = onnx.load(SRC, load_external_data=False)
try:
    mi = onnx.shape_inference.infer_shapes(m, strict_mode=False, data_prop=True)
except Exception as ex:
    print('shape inference failed:', ex); mi = m
g = mi.graph

def dims_of(name):
    for vi in list(g.value_info) + list(g.output) + list(g.input):
        if vi.name == name:
            tt = vi.type.tensor_type
            return [d.dim_value if d.HasField('dim_value') else None for d in tt.shape.dim]
    return None

inits = {i.name: i for i in g.initializer}
new_inits = {}
nslice = 0
unresolved = 0
for n in g.node:
    if n.op_type != 'Slice' or len(n.input) < 3:
        continue
    vals = []
    for k in range(4):
        inp = n.input[1+k] if 1+k < len(n.input) else None
        vals.append(numpy_helper.to_array(inits[inp]) if inp in inits else None)
    while len(vals) < 4: vals.append(None)
    begins, ends, axes, steps = vals
    if begins is None or ends is None: continue
    data_dims = dims_of(n.input[0])
    nd = len(begins) if axes is None else len(axes)
    axes_v = [int(a) for a in axes] if axes is not None else list(range(nd))
    steps_v = [int(s) for s in steps] if steps is not None else [1]*nd
    nb, ne = [], []
    for k in range(nd):
        ax = axes_v[k]
        dim = data_dims[ax] if data_dims and ax < len(data_dims) and data_dims[ax] is not None else None
        b = int(begins[k]); e = int(ends[k])
        if dim is not None:
            if b < 0: b += dim
            if b > 2**31-1: b = dim
            if e > 2**31-1: e = dim
            if e < -2**31: e += dim
            b = max(b, 0)
        else:
            unresolved += 1
        nb.append(b); ne.append(e if e is not None else 2**31-1)
    suf = n.name.replace('/', '_').replace(':', '_')
    names_new = []
    for tag, arr in (('b', nb), ('e', ne), ('a', axes_v), ('s', steps_v)):
        nm = f'{suf}_{tag}_v4'
        new_inits[nm] = numpy_helper.from_array(np.asarray(arr, dtype=np.int32), nm)
        names_new.append(nm)
    for k in range(4):
        idx = 1+k
        if idx < len(n.input):
            n.input[idx] = names_new[k]
        else:
            n.input.append(names_new[k])
    nslice += 1
print('slices rewritten:', nslice, '| unresolved dims:', unresolved)

# global sweep: remaining int64 inits -> int32 (values must fit)
conv = 0
out_inits = []
for init in g.initializer:
    if init.data_type == TensorProto.INT64:
        arr = numpy_helper.to_array(init)
        if arr.size and (arr.max(initial=0) > 2**31-1 or arr.min(initial=0) < -2**31):
            print('STILL-INT64-overflow:', init.name, arr.ravel()[:3].tolist())
            out_inits.append(init); continue
        out_inits.append(numpy_helper.from_array(arr.astype(np.int32), init.name))
        conv += 1
    else:
        out_inits.append(init)
del g.initializer[:]
g.initializer.extend(out_inits)
for nm, t in new_inits.items():
    g.initializer.append(t)
print('global int64->int32:', conv)
onnx.save_model(mi, DST, save_as_external_data=True, all_tensors_to_one_file=True, location='fix5.data', size_threshold=1024)
print('saved', DST)
