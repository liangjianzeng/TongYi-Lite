import onnx, sys
m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v2.onnx', load_external_data=False)
g = m.graph
prod = {}
for n in g.node:
    for o in n.output:
        prod[o] = n

def vinfo(name):
    for vi in list(g.input) + list(g.value_info) + list(g.output):
        if vi.name == name:
            t = vi.type.tensor_type
            return f"{vi.name}: elem={t.elem_type} shape={[d.dim_value if d.HasField('dim_value') else d.dim_param for d in t.shape.dim]}"
    return None

def show(n, depth=0, memo=None):
    if memo is None: memo = set()
    pad = '  ' * depth
    vi = vinfo(n.output[0])
    print(f"{pad}{n.name} [{n.op_type}] out={n.output[0]} {vi or ''}")
    print(f"{pad}   attrs: " + ' '.join(f"{a.name}={a.i if a.type==2 else list(a.ints) if a.type==7 else a.f}" for a in n.attribute))
    if depth >= 6 or n.name in memo: return
    memo.add(n.name)
    for i in n.input:
        if i in prod:
            show(prod[i], depth + 1, memo)
        else:
            print(f"{pad}  IN {i} (graph input/const)")

# follow chain back from /Transpose_4
for n in g.node:
    if n.name == '/Transpose_4':
        show(n)
        break

# also dump initializers feeding Cast_3 if constant
init = {t.name: t for t in g.initializer}
print('---- initializers (first 10, by name) referenced in shown chain above ----')
