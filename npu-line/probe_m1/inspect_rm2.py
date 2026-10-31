import onnx
m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v3.onnx', load_external_data=False)
for n in m.graph.node:
    if n.name == '/ReduceMean':
        print('op_type', n.op_type)
        print('inputs', list(n.input))
        print('outputs', list(n.output))
        for a in n.attribute:
            print('attr', a.name, 'type', a.type, 'i=', a.i, 'ints=', list(a.ints))
        break
else:
    print('not found')
# also check opset
print('opsets', [(o.domain, o.version) for o in m.opset_import])
