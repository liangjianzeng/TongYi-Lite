import subprocess, os
import onnx
from onnx import helper, TensorProto
import numpy as np

def conv(name):
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
    env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
    exe = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
    r = subprocess.run(['python3', exe, '--input_network', f'/mnt/e/MyLLM_exp/{name}.onnx',
                        '--output_path', f'/mnt/e/MyLLM_exp/{name}_qnn'], env=env, capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-2:]
    print(f'== {name}: rc={r.returncode}')
    for l in tail: print('   ', l[:150])

# 1: RMSNorm-style: Pow -> ReduceSum(axes as INPUT, opset13+) -> Div -> rsqrt via Sqrt+Div -> Mul
def make_rms(path):
    nodes = [
        helper.make_node('Pow', ['x', 'two'], ['p'], name='P'),
        helper.make_node('ReduceSum', ['p', 'axes1'], ['s'], keepdims=1, name='RS'),
        helper.make_node('Div', ['s', 'n'], ['m'], name='D1'),
        helper.make_node('Sqrt', ['m'], ['sq'], name='SQ'),
        helper.make_node('Div', ['one', 'sq'], ['rs'], name='D2'),
        helper.make_node('Mul', ['x', 'rs'], ['mm'], name='M1'),
        helper.make_node('Mul', ['mm', 'w'], ['z'], name='M2'),
    ]
    inits = [
        helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0]),
        helper.make_tensor('axes1', TensorProto.INT64, [1], [2]),
        helper.make_tensor('n', TensorProto.FLOAT16, [], [16.0]),
        helper.make_tensor('one', TensorProto.FLOAT16, [], [1.0]),
        helper.make_tensor('w', TensorProto.FLOAT16, [16], np.ones(16, np.float16)),
    ]
    graph = helper.make_graph(nodes, 't', [helper.make_tensor_value_info('x', TensorProto.FLOAT16, [1, 8, 16])],
        [helper.make_tensor_value_info('z', TensorProto.FLOAT16, [1, 8, 16])], inits)
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 8
    model = onnx.shape_inference.infer_shapes(model)
    onnx.save(model, path)

# 2: Softmax op fp16 on attention-like shape
def make_sm(path):
    nodes = [helper.make_node('Softmax', ['x'], ['z'], axis=-1, name='SM')]
    graph = helper.make_graph(nodes, 't', [helper.make_tensor_value_info('x', TensorProto.FLOAT16, [1, 4, 2048, 512])],
        [helper.make_tensor_value_info('z', TensorProto.FLOAT16, [1, 4, 2048, 512])], [])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 8
    model = onnx.shape_inference.infer_shapes(model)
    onnx.save(model, path)

make_rms('/mnt/e/MyLLM_exp/tiny_rms.onnx')
make_sm('/mnt/e/MyLLM_exp/tiny_sm.onnx')
conv('tiny_rms')
conv('tiny_sm')
