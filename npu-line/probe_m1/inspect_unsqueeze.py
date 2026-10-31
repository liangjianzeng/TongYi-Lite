import onnx
from onnx import numpy_helper
m = onnx.load(r'E:/MyLLM_exp/spark_prefill_seq512_fix4.onnx', load_external_data=False)
g = m.graph
inits = {i.name: i for i in g.initializer}
prod = {}
for n in g.node:
    for o in n.output:
        prod[o] = n

def describe(name, depth=0, seen=None):
    if seen is None: seen = set()
    pad = '  ' * depth
    if name in inits:
        arr = numpy_helper.to_array(inits[name])
        print(f'{pad}{name} INIT dtype={inits[name].data_type} val={arr.tolist()[:8]}')
        return
    n = prod.get(name)
    if n is None:
        print(f'{pad}{name} <graph input/unknown>')
        return
    if id(n) in seen:
        print(f'{pad}{name} <cycle {n.op_type}>')
        return
    seen.add(id(n))
    print(f'{pad}{name} <- {n.op_type} ({n.name})')
    for inp in n.input:
        describe(inp, depth+1, seen)

targets = [n for n in g.node if n.op_type == 'Unsqueeze']
print('unsqueeze nodes:', len(targets))
for n in targets:
    axes_inp = n.input[1] if len(n.input) > 1 else None
    if axes_inp and axes_inp not in inits:
        print('=== NON-CONST axes:', n.name, n.input, '->', n.output)
        describe(axes_inp, 1)
        # limit to first 5
        targets_count = sum(1 for x in targets if (len(x.input)>1 and x.input[1] not in inits))
        print('non-const-axes unsqueezes total:', targets_count)
        break
else:
    print('all unsqueeze axes are inits')
