import onnx, sys
m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v2.onnx', load_external_data=False)
g = m.graph
# index nodes by output name
prod = {}
for n in g.node:
    for o in n.output:
        prod[o] = n

def vinfo(name):
    for vi in list(g.input) + list(g.value_info) + list(g.output):
        if vi.name == name:
            t = vi.type.tensor_type
            return f"{vi.name}: elem={t.elem_type} shape={[d.dim_value if d.HasField('dim_value') else d.dim_param for d in t.shape.dim]}"
    return f"{name}: <no value_info>"

target = sys.argv[1] if len(sys.argv) > 1 else '/Transpose_4'
# find node whose name matches
for n in g.node:
    if n.name == target or n.name == target.lstrip('/'):
        print('NODE', n.name, n.op_type)
        for i in n.input:
            print('  IN ', vinfo(i), '<- producer:', prod[i].op_type, prod[i].name if i in prod else 'graph-input' if i in [x.name for x in g.input] else '?')
        for o in n.output:
            print('  OUT', vinfo(o))
        break
else:
    print('node not found; showing first 20 Transpose names')
    c = 0
    for n in g.node:
        if n.op_type == 'Transpose':
            print(n.name, [i for i in n.input], '->', n.output[0])
            c += 1
            if c > 20: break
