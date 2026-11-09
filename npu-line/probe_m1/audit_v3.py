import onnx, collections
from onnx import TensorProto
m = onnx.load('/mnt/e/MyLLM_exp/spark_prefill_v3.onnx', load_external_data=False)
g = m.graph
ops = collections.Counter(n.op_type for n in g.node)
print('OPS', sorted(ops.items(), key=lambda kv:-kv[1]))
# dtype map
dt = {}
def name_dt(vi):
    return vi.type.tensor_type.elem_type
for vi in list(g.input)+list(g.output)+list(g.value_info):
    dt[vi.name] = name_dt(vi)
for init in g.initializer:
    dt[init.name] = init.data_type
DT={1:'f32',2:'u8',3:'i8',4:'u16',5:'i16',6:'i32',7:'i64',9:'bool',10:'f16',11:'f64',12:'u32',13:'u64'}
# find nodes producing/consuming mixed fp16/fp32
mixed = 0
for n in g.node:
    dts = [dt.get(i) for i in list(n.input)+list(n.output) if i and i in dt]
    f16 = sum(1 for d in dts if d==10); f32 = sum(1 for d in dts if d==1)
    if f16 and f32:
        mixed += 1
        if mixed <= 20:
            print('MIXED', n.op_type, n.name, [(i, DT.get(dt.get(i))) for i in list(n.input)+list(n.output) if i])
print('total_mixed_nodes', mixed)
# Cast nodes detail
for n in g.node:
    if n.op_type=='Cast':
        to = [a.i for a in n.attribute if a.name=='to']
        print('CAST', n.name, n.input, '->', n.output, 'to=', to, DT.get(dt.get(n.input[0], -1)))
# initializer dtype histogram
idt = collections.Counter(i.data_type for i in g.initializer)
print('INIT_DT', dict(idt))
