import subprocess, os

def conv(name, ld):
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = ld
    env['PYTHONPATH'] = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python'
    exe = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter'
    r = subprocess.run(['python3', exe, '--input_network', f'/mnt/e/MyLLM_exp/{name}.onnx',
                        '--output_path', f'/mnt/e/MyLLM_exp/{name}_qnn'], env=env, capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-2:]
    print(f'== {name} [{ld[:60]}]: rc={r.returncode}')
    for l in tail: print('   ', l[:150])

CPPX = '/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
QAIRT = '/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang'
conv('tiny_negax', QAIRT)
conv('tiny_rms', QAIRT)
conv('tiny_sm', QAIRT)
