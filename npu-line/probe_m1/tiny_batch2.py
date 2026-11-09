import onnx, subprocess, os
from onnx import helper, TensorProto
import numpy as np

def model_of(nodes, inits, outname='z'):
    graph = helper.make_graph(nodes, 't',
        [helper.make_tensor_value_info('x', TensorProto.FLOAT16, [1,8,16])],
        [helper.make_tensor_value_info(outname, TensorProto.FLOAT16, [1,8,16])], inits)
    m = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    m.ir_version = 8
    return onnx.shape_inference.infer_shapes(m)

two = helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0])
one = helper.make_tensor('one', TensorProto.FLOAT16, [], [1.0])
def rm(name='m', axes=[-1]):
    return helper.make_node('ReduceMean', ['x'], [name], axes=axes, keepdims=1)

variants = {
 # ta: Div(computed m, scalar const)
 'ta_div_m_const': ([rm(), helper.make_node('Div',['m','one'],['z'])], [two, one]),
 # tb: Div(two computed)
 'tb_div_m_m2': ([rm('m'), rm('m2',axes=[-2]), helper.make_node('Div',['m','m2'],['z'])], [two]),
 # tc: Div(const, computed)
 'tc_div_const_m': ([rm(), helper.make_node('Div',['one','m'],['z'])], [two, one]),
 # td: Mul(x, Sqrt(m)) - does Sqrt output pass through Mul?
 'td_mul_sqrt': ([rm(), helper.make_node('Sqrt',['m'],['sq']), helper.make_node('Mul',['x','sq'],['z'])], [two]),
 # te: Sqrt output as graph output directly
 'te_sqrt_out': ([rm(), helper.make_node('Sqrt',['m'],['z'])], [two]),
 # tf: Div with two computed where one is Sqrt output
 'tf_div_sq_m': ([rm(), helper.make_node('Sqrt',['m'],['sq']), helper.make_node('Div',['sq','m'],['z'])], [two]),
 # tg: Div(computed, computed) both from Mul chain
 'tg_div_mul': ([helper.make_node('Mul',['x','x'],['a']), helper.make_node('Mul',['x','two'],['b']), helper.make_node('Div',['a','b'],['z'])], [two]),
}
env = dict(os.environ)
env['LD_LIBRARY_PATH'] = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
conv = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
for nm,(nodes,inits) in variants.items():
    p = f'/mnt/e/MyLLM_exp/tc_{nm}.onnx'
    onnx.save(model_of(nodes, inits), p)
    r = subprocess.run(['python3', conv, '--input_network', p,
                        '--output_path', f'/mnt/e/MyLLM_exp/tc_{nm}_qnn'], env=env, capture_output=True, text=True)
    out = (r.stdout + r.stderr)
    key = 'OK'
    if r.returncode != 0:
        for line in out.splitlines():
            if 'validateQnnOpConfig' in line:
                key = line.strip()[:130]; break
        else:
            key = out.strip().splitlines()[-1][:130]
    print(f'{nm}: rc={r.returncode} {key}')
