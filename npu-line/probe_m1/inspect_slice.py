import onnx
from onnx import numpy_helper
m = onnx.load(r'E:/MyLLM_exp/spark_prefill_seq512.onnx', load_external_data=False)
g = m.graph
inits = {i.name: i for i in g.initializer}
slices = [n for n in g.node if n.op_type == 'Slice']
print('total Slice nodes:', len(slices))
for n in slices[:10]:
    print('---', n.name, n.input, '->', n.output)
    for inp in n.input[1:]:
        if inp in inits:
            print('   init', inp, '=', numpy_helper.to_array(inits[inp]).tolist())
        else:
            print('   non-init input:', inp)
# check datatypes of slice param initializers
dts = set()
for n in slices:
    for inp in n.input[1:]:
        if inp in inits:
            dts.add(inits[inp].data_type)
print('slice param data_types:', dts, '(1=float32,2=uint8,3=int8,5=int16,6=int32,7=int64)')
# also count Cast nodes
casts = [n for n in g.node if n.op_type == 'Cast']
print('Cast nodes:', len(casts))
