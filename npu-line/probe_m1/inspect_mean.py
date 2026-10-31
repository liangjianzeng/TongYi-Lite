import onnx
from onnx import numpy_helper
m = onnx.load(r'E:/MyLLM_exp/spark_prefill_seq512_fix4.onnx', load_external_data=False)
g = m.graph
inits = {i.name: i for i in g.initializer}
consts = {}
for n in g.node:
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.name == 'value':
                consts[n.output[0]] = numpy_helper.to_array(a.t)
targets = [n for n in g.node if n.op_type in ('ReduceMean','ReduceSum','ReduceMax','ReduceMin')]
print('reduce nodes:', len(targets))
for n in targets[:4]:
    print('---', n.name, n.input, '->', n.output)
    for a in n.attribute: print('   attr', a.name, a)
    for inp in n.input[1:]:
        if inp in inits:
            print('   init', inp, numpy_helper.to_array(inits[inp]).tolist(), inits[inp].data_type)
        elif inp in consts:
            print('   const-node', inp, consts[inp].tolist())
        else:
            print('   DYNAMIC input:', inp, '<- producer:', next((p.op_type+':'+p.name for p in g.node if p.output and p.output[0]==inp), '?'))
print('opset:', [(o.domain, o.version) for o in m.opset_import])
