# Fix v2: convert ALL int64 initializers to int32 (QAIRT modeltools is int32-era).
import onnx
from onnx import numpy_helper, TensorProto
import numpy as np

SRC = r'E:/MyLLM_exp/spark_prefill_seq512_fix.onnx'
DST = r'E:/MyLLM_exp/spark_prefill_seq512_fix2.onnx'

m = onnx.load(SRC, load_external_data=False)
g = m.graph
converted = 0
kept = []
overflow = []
for init in g.initializer:
    if init.data_type == TensorProto.INT64:
        arr = numpy_helper.to_array(init)
        if arr.size and (np.abs(arr[arr.dtype != object]).max(initial=0) > 2**31 - 1 or arr.min(initial=0) < -2**31):
            overflow.append((init.name, arr.ravel()[:4].tolist()))
            kept.append(init)  # leave as-is
            continue
        t = numpy_helper.from_array(arr.astype(np.int32), init.name)
        kept.append(t)
        converted += 1
    else:
        kept.append(init)
del g.initializer[:]
g.initializer.extend(kept)
print('converted to int32:', converted, '| left int64 (overflow):', overflow[:5], 'count', len(overflow))
onnx.save(m, DST)
print('saved', DST)
