import onnx, subprocess, os
from onnx import helper, TensorProto
import numpy as np

def model_of(nodes, inits, outname='z', outshape=[1,8,16]):
    graph = helper.make_graph(nodes, 't',
        [helper.make_tensor_value_info('x', TensorProto.FLOAT16, [1,8,16])],
        [helper.make_tensor_value_info(outname, TensorProto.FLOAT16, outshape)], inits)
    m = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    m.ir_version = 8
    m = onnx.shape_inference.infer_shapes(m)
    return m

variants = {}
# V1 baseline: Div(scalar one, Sqrt(mean))  -> expect fail
def v1():
    two = helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0])
    one = helper.make_tensor('one', TensorProto.FLOAT16, [], [1.0])
    n = [helper.make_node('Pow',['x','two'],['p']),
         helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Sqrt',['m'],['sq']),
         helper.make_node('Div',['one','sq'],['r']),
         helper.make_node('Mul',['x','r'],['z'])]
    return model_of(n, [two, one])
# V2: full-shaped ones
def v2():
    two = helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0])
    one = helper.make_tensor('one', TensorProto.FLOAT16, [1,8,16], np.ones(128, np.float16))
    n = [helper.make_node('Pow',['x','two'],['p']),
         helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Sqrt',['m'],['sq']),
         helper.make_node('Div',['one','sq'],['r']),
         helper.make_node('Mul',['x','r'],['z'])]
    return model_of(n, [two, one])
# V3: Reciprocal(Sqrt)
def v3():
    two = helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0])
    n = [helper.make_node('Pow',['x','two'],['p']),
         helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Sqrt',['m'],['sq']),
         helper.make_node('Reciprocal',['sq'],['r']),
         helper.make_node('Mul',['x','r'],['z'])]
    return model_of(n, [two])
# V4: Pow(-0.5)
def v4():
    two = helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0])
    half = helper.make_tensor('half', TensorProto.FLOAT16, [], [-0.5])
    n = [helper.make_node('Pow',['x','two'],['p']),
         helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Pow',['m','half'],['r']),
         helper.make_node('Mul',['x','r'],['z'])]
    return model_of(n, [two, half])
# V5: scalar add eps then rsqrt path full fp16 with scalar
def v5():
    eps = helper.make_tensor('eps', TensorProto.FLOAT16, [], [1e-5])
    half = helper.make_tensor('half', TensorProto.FLOAT16, [], [-0.5])
    n = [helper.make_node('ReduceMean',['x'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Add',['m','eps'],['me']),
         helper.make_node('Pow',['me','half'],['r']),
         helper.make_node('Mul',['x','r'],['z'])]
    return model_of(n, [eps, half])
# V6: everything fp32 inputs but output cast to f16
def v6():
    two = helper.make_tensor('two', TensorProto.FLOAT, [], [2.0])
    n = [helper.make_node('Pow',['x','two'],['p']),
         helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Sqrt',['m'],['sq']),
         helper.make_node('Reciprocal',['sq'],['r']),
         helper.make_node('Mul',['x','r'],['z'])]
    return model_of(n, [two])

names = []
for nm, fn in [('v1_scalar_div',v1),('v2_full_div',v2),('v3_recip',v3),('v4_pow',v4),('v5_eps',v5),('v6_f32_sqrt',v6)]:
    p = f'/mnt/e/MyLLM_exp/tb_{nm}.onnx'
    onnx.save(fn(), p); names.append(nm)

env = dict(os.environ)
env['LD_LIBRARY_PATH'] = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
conv = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
for nm in names:
    r = subprocess.run(['python3', conv, '--input_network', f'/mnt/e/MyLLM_exp/tb_{nm}.onnx',
                        '--output_path', f'/mnt/e/MyLLM_exp/tb_{nm}_qnn'], env=env, capture_output=True, text=True)
    out = (r.stdout + r.stderr)
    key = 'OK'
    if r.returncode != 0:
        for line in out.splitlines():
            if 'validateQnnOpConfig' in line or 'mismatching' in line or 'Datatype' in line:
                key = line.strip()[:120]; break
        else:
            key = out.strip().splitlines()[-1][:120]
    print(f'{nm}: rc={r.returncode} {key}')
