# -*- coding: utf-8 -*-
# Patch v5 against PRISTINE QAIRT op_graph_optimizations.py:
# synthesized norm weight/bias constants must not be fp32. Site A derives dtype from
# the gamma ConstantOp's own tensor; sites B/C default np.float16 (this model is
# uniformly fp16; fp32 defaults are what break QNN same-dtype validation).
import paramiko
HOST = '<redacted-tailscale-pc>'; USER = 'jianz'; PW = '<redacted-ssh-passwd>'
REMOTE = 'D:/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/converter_ir/op_graph_optimizations.py'

A_OLD = "                    bias_tensor = tensor if tensor is not None else np.zeros(tensor_dimensions)\n"
A_NEW = (
    "                    _npdt = np.float16\n"
    "                    try:\n"
    "                        _pt = getattr(node.op, 'tensor', None)\n"
    "                        if _pt is not None and hasattr(_pt, 'dtype'):\n"
    "                            _npdt = _pt.dtype\n"
    "                    except Exception:\n"
    "                        pass\n"
    "                    bias_tensor = tensor if tensor is not None else np.zeros(tensor_dimensions, dtype=_npdt)\n"
)
B_OLD = "                    weight_tensor = tensor if tensor is not None else np.ones(tensor_dimensions)\n"
B_NEW = (
    "                    # np.float16: pattern activations are fp16; fp32 ones/zeros break\n"
    "                    # QNN RMS_NORM same-dtype validation (see M1 conv log [C7]/[C9])\n"
    "                    weight_tensor = tensor if tensor is not None else np.ones(tensor_dimensions, dtype=np.float16)\n"
)
C_OLD = "            bias_tensor = np.zeros(tensor_dimensions)\n"
C_NEW = "            bias_tensor = np.zeros(tensor_dimensions, dtype=np.float16)\n"

c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=20)
sftp = c.open_sftp()
f = sftp.open(REMOTE, 'r'); src = f.read().decode('utf-8'); f.close()
n = 0
for old, new, tag in ((A_OLD, A_NEW, 'A'), (B_OLD, B_NEW, 'B'), (C_OLD, C_NEW, 'C')):
    cnt = src.count(old)
    print('site %s: %d' % (tag, cnt), flush=True)
    if cnt:
        src = src.replace(old, new)
        n += cnt
if n:
    f = sftp.open(REMOTE, 'w'); f.write(src); f.close()
    print('PATCHED v5 OK, sites:', n, flush=True)
else:
    print('NOTHING CHANGED (unexpected state)', flush=True)
sftp.close(); c.close()
