# Fix QAIRT-incompatible Slice params: int64 -> int32, resolve INT64_MAX/MIN via shape inference.
import onnx
from onnx import numpy_helper, TensorProto
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix.onnx'

m = onnx.load(SRC, load_external_data=False)
try:
    mi = onnx.shape_inference.infer_shapes(m, strict_mode=False, data_prop=True)
except Exception as ex:
    print('shape inference failed, falling back to raw:', ex)
    mi = m
g = mi.graph

# value -> dims map from value_info / outputs / inputs
def dims_of(name):
    for vi in list(g.value_info) + list(g.output) + list(g.input):
        if vi.name == name:
            tt = vi.type.tensor_type
            if tt.HasField('elem_type'):
                return [d.dim_value if d.HasField('dim_value') else None for d in tt.shape.dim]
    return None

inits = {i.name: i for i in g.initializer}
fixed = 0
new_inits = {}
remove_names = set()
for n in g.node:
    if n.op_type != 'Slice':
        continue
    params = {}
    if len(n.input) == 1:  # attribute-style (opset<10) unlikely here
        continue
    names = n.input[1:5]
    vals = []
    for k, inp in enumerate(names):
        if inp in inits:
            arr = numpy_helper.to_array(inits[inp])
        else:
            arr = None
        vals.append(arr)
    while len(vals) < 4:
        vals.append(None)
    begins, ends, axes, steps = vals
    if begins is None or ends is None:
        continue
    data_dims = dims_of(n.input[0])
    nd = len(begins) if axes is None else len(axes)
    axes_v = list(axes) if axes is not None else list(range(nd))
    steps_v = list(steps) if steps is not None else [1]*nd
    nb, ne = [], []
    for k in range(nd):
        ax = axes_v[k]
        dim = data_dims[ax] if data_dims and ax < len(data_dims) and data_dims[ax] is not None else None
        b = int(begins[k]) if begins is not None and begins[k] is not None else 0
        e = int(ends[k]) if ends is not None and ends[k] is not None else None
        if dim is not None:
            if b < 0: b += dim
            if b > 2**31 - 1: b = dim
            if e is not None and e > 2**31 - 1: e = dim      # INT64_MAX -> concrete dim
            if e is not None and e < -2**31: e += dim
        else:
            if e is not None and e > 2**31 - 1:
                print('WARN: cannot resolve INT64_MAX end, no dim for axis', ax, n.name)
        nb.append(max(b, 0))
        ne.append(e if e is not None else 2**31 - 1)
    def mk_init(name, arr):
        t = numpy_helper.from_array(np.asarray(arr, dtype=np.int32), name)
        return t
    suf = n.name.replace('/', '_')
    names_new = []
    for tag, arr in (('b', nb), ('e', ne), ('a', axes_v), ('s', steps_v)):
        nm = f'{suf}_{tag}_i32'
        new_inits[nm] = mk_init(nm, arr)
        names_new.append(nm)
    for old in names:
        if old in inits:
            remove_names.add(old)
    for k in range(4):
        if k < len(n.input[1:]) and n.input[1+k] in inits:
            n.input[1+k] = names_new[k]
        elif k >= len(n.input[1:]):
            n.input.append(names_new[k])
        # non-init inputs left as-is (dynamic slices) -- none expected
    fixed += 1

# apply initializer changes
keep = [i for i in g.initializer if i.name not in remove_names]
for nm, t in new_inits.items():
    keep.append(t)
del g.initializer[:]
g.initializer.extend(keep)
print('fixed slices:', fixed)
onnx.save(mi, DST)
print('saved', DST)
