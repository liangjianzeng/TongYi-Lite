# Fix v3: onnxsim constant-fold first, then int64->int32 sweep, save for QAIRT.
import onnx
from onnx import numpy_helper, TensorProto
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512.onnx'
SIM = r'E:/MyLLM_exp/spark_prefill_seq512_sim.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix3.onnx'

import onnxsim
print('running onnxsim (constant folding)...', flush=True)
m = onnx.load(SRC)  # loads external data
msim, ok = onnxsim.simplify(m)
assert ok, 'onnxsim failed'
onnx.save(msim, SIM)
print('sim saved', flush=True)

m2 = onnx.load(SIM, load_external_data=False)
g = m2.graph
converted = 0
kept = []
for init in g.initializer:
    if init.data_type == TensorProto.INT64:
        arr = numpy_helper.to_array(init)
        if arr.size and (arr.max(initial=0) > 2**31 - 1 or arr.min(initial=0) < -2**31):
            print('overflow kept:', init.name, arr.ravel()[:4].tolist())
            kept.append(init)
            continue
        kept.append(numpy_helper.from_array(arr.astype(np.int32), init.name))
        converted += 1
    else:
        kept.append(init)
del g.initializer[:]
g.initializer.extend(kept)
print('int64->int32 converted:', converted, flush=True)
onnx.save(m2, DST)
print('saved', DST, flush=True)
