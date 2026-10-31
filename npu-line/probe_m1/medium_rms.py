import onnx, subprocess, os
from onnx import helper, TensorProto
import numpy as np

def mk(nodes, inits, wdim=64):
    graph = helper.make_graph(nodes, 't',
        [helper.make_tensor_value_info('x', TensorProto.FLOAT16, [1,8,wdim])],
        [helper.make_tensor_value_info('z', TensorProto.FLOAT16, [1,8,wdim])], inits)
    m = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    m.ir_version = 8
    return onnx.shape_inference.infer_shapes(m)

wdim=64
w = helper.make_tensor('w', TensorProto.FLOAT16, [wdim], np.ones(wdim, np.float16))
eps = helper.make_tensor('eps', TensorProto.FLOAT16, [], [1e-5])
two = helper.make_tensor('two', TensorProto.FLOAT16, [], [2.0])
half = helper.make_tensor('half', TensorProto.FLOAT16, [], [-0.5])

def rms_nodes(rsqrt_mode, order):
    n = [helper.make_node('Pow',['x','two'],['p']),
         helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
         helper.make_node('Add',['m','eps'],['me'])]
    if rsqrt_mode=='pow':
        n.append(helper.make_node('Pow',['me','half'],['r']))
    else:
        n += [helper.make_node('Sqrt',['me'],['sq']), helper.make_node('Reciprocal',['sq'],['r'])]
    if order=='x_first':
        n += [helper.make_node('Mul',['x','r'],['mm']), helper.make_node('Mul',['mm','w'],['z'])]
    else:  # w first
        n += [helper.make_node('Mul',['x','w'],['xw']), helper.make_node('Mul',['xw','r'],['z'])]
    return n

variants = {
 'm1_pow_xfirst': mk(rms_nodes('pow','x_first'), [w,eps,two,half]),
 'm2_pow_wfirst': mk(rms_nodes('pow','w_first'), [w,eps,two,half]),
 'm3_recip_xfirst': mk(rms_nodes('recip','x_first'), [w,eps,two,half]),
 'm4_recip_wfirst': mk(rms_nodes('recip','w_first'), [w,eps,two,half]),
 # m5: no eps add (avoids possible pattern element)
 'm5_noeps': mk([helper.make_node('Pow',['x','two'],['p']),
                 helper.make_node('ReduceMean',['p'],['m'], axes=[-1], keepdims=1),
                 helper.make_node('Pow',['m','half'],['r']),
                 helper.make_node('Mul',['x','r'],['mm']),
                 helper.make_node('Mul',['mm','w'],['z'])], [w,two,half]),
}
env = dict(os.environ)
env['LD_LIBRARY_PATH'] = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
conv = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
for nm, mdl in variants.items():
    p = f'/mnt/e/MyLLM_exp/{nm}.onnx'
    onnx.save(mdl, p)
    r = subprocess.run(['python3', conv, '--input_network', p,
                        '--output_path', f'/mnt/e/MyLLM_exp/{nm}_qnn'], env=env, capture_output=True, text=True)
    out = (r.stdout + r.stderr)
    key='OK'
    if r.returncode!=0:
        for line in out.splitlines():
            if 'validateQnnOpConfig' in line or 'ERROR' in line:
                key=line.strip()[:140]; break
        else: key=out.strip().splitlines()[-1][:140]
    print(f'{nm}: rc={r.returncode} {key}')
