# Tiny-graph reproduction: does a Cast(fp32) chain feeding Transpose break the QNN converter,
# and does the fp16-direct variant pass?
import onnx
from onnx import helper, TensorProto
import numpy as np

def make(path, with_casts):
    inits = []
    nodes = []
    # input fp16 [1,4,512,256]
    cur = 'x'
    if with_casts:
        nodes.append(helper.make_node('Cast', [cur], ['c1'], to=TensorProto.FLOAT, name='C_up'))
        cos = helper.make_tensor('cos', TensorProto.FLOAT, [1,1,512,256], np.ones(512*256, np.float32))
        inits.append(cos)
        nodes.append(helper.make_node('Mul', ['c1', 'cos'], ['m1'], name='M1'))
        nodes.append(helper.make_node('Cast', ['m1'], ['c2'], to=TensorProto.FLOAT16, name='C_dn'))
        cur = 'c2'
    else:
        cos = helper.make_tensor('cos', TensorProto.FLOAT16, [1,1,512,256], np.ones(512*256, np.float16))
        inits.append(cos)
        nodes.append(helper.make_node('Mul', [cur, 'cos'], ['m1'], name='M1'))
        cur = 'm1'
    nodes.append(helper.make_node('Transpose', [cur], ['t2'], perm=[0,1,3,2], name='T_out'))
    graph = helper.make_graph(
        nodes, 'tiny', [helper.make_tensor_value_info('x', TensorProto.FLOAT16, [1,4,512,256])],
        [helper.make_tensor_value_info('t2', TensorProto.FLOAT16, [1,4,512,256])], inits)
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 8
    model = onnx.shape_inference.infer_shapes(model)
    onnx.save(model, path)
    print('saved', path, 'with_casts=', with_casts)

make('/mnt/e/MyLLM_exp/tiny_cast.onnx', True)
make('/mnt/e/MyLLM_exp/tiny_nocast.onnx', False)

import subprocess, os
env = dict(os.environ)
env['LD_LIBRARY_PATH'] = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
conv = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
for name in ('tiny_cast', 'tiny_nocast'):
    r = subprocess.run(['python3', conv, '--input_network', f'/mnt/e/MyLLM_exp/{name}.onnx',
                        '--output_path', f'/mnt/e/MyLLM_exp/{name}_qnn'],
                       env=env, capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-4:]
    print(f'== {name}: rc={r.returncode}')
    for l in tail: print('   ', l[:160])
