import onnx, numpy as np, collections
from onnx import numpy_helper
m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v3.onnx', load_external_data=False)
g = m.graph
const_out = {}
for n in g.node:
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.name == 'value':
                const_out[n.output[0]] = a.t
for init in g.initializer:
    const_out[init.name] = init

pat = collections.Counter()
for n in g.node:
    if n.op_type != 'Div':
        continue
    a, b = n.input[0], n.input[1]
    a_is_c = a in const_out
    b_is_c = b in const_out
    if a_is_c:
        t = numpy_helper.to_array(const_out[a])
        pat[('const_first', str(t.dtype), t.shape, float(t.ravel()[0]) if t.size<=4 else 'big')] += 1
    elif b_is_c:
        pat[('const_second',)] += 1
    else:
        pat[('computed_both',)] += 1
for k, v in sorted(pat.items(), key=lambda kv: -kv[1]):
    print(v, k)
# also Mul with const first (potential future issue)
pat2 = collections.Counter()
for n in g.node:
    if n.op_type == 'Mul':
        a, b = n.input[0], n.input[1]
        if a in const_out and b not in const_out:
            t = numpy_helper.to_array(const_out[a])
            pat2[('mul_const_first', str(t.dtype), t.shape)] += 1
for k, v in sorted(pat2.items(), key=lambda kv: -kv[1])[:10]:
    print(v, k)
