import onnx
from onnx import helper, TensorProto
import numpy as np

def make(path, axes, dt=TensorProto.FLOAT16):
    x = helper.make_tensor_value_info('x', dt, [1, 8, 16])
    node = helper.make_node('ReduceMean', ['x'], ['y'], axes=axes, keepdims=1, name='RM')
    w = helper.make_tensor('w', dt, [16], np.ones(16, np.float16 if dt==TensorProto.FLOAT16 else np.float32))
    n2 = helper.make_node('Mul', ['y', 'w'], ['z'], name='M')
    graph = helper.make_graph([node, n2], 't', [x],
        [helper.make_tensor_value_info('z', dt, [1, 8, 16])], [w])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 8
    model = onnx.shape_inference.infer_shapes(model)
    onnx.save(model, path)

make('/mnt/e/MyLLM_exp/tiny_negax.onnx', [-1])
make('/mnt/e/MyLLM_exp/tiny_posax.onnx', [2])
make('/mnt/e/MyLLM_exp/tiny_f32.onnx', [-1], TensorProto.FLOAT)
make('/mnt/e/MyLLM_exp/tiny_f32p.onnx', [2], TensorProto.FLOAT)

import subprocess, os
env = dict(os.environ)
env['LD_LIBRARY_PATH'] = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
conv = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
for name in ('tiny_negax', 'tiny_posax', 'tiny_f32', 'tiny_f32p'):
    r = subprocess.run(['python3', conv, '--input_network', f'/mnt/e/MyLLM_exp/{name}.onnx',
                        '--output_path', f'/mnt/e/MyLLM_exp/{name}_qnn'], env=env, capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
    print(f'== {name}: rc={r.returncode}')
    for l in tail: print('   ', l[:150])
