# -*- coding: utf-8 -*-
# Converter wrapper: replicate qnn-onnx-converter main() and, between optimizer and
# backend, fix the QAIRT 2.44 MATCH_RMSNORM bug: synthesized zero-beta / ones-weight
# constants are created fp32 while the pattern is fp16 -> QNN same-dtype validation
# rejects the fused RMS_NORM (0x232 != 0x216). Here IR buffers already carry dtypes,
# so the fixup is deterministic: for every RmsNorm op, cast fp32 constant inputs to
# the dtype of the op's main (first) input buffer.
import sys
import numpy as np

QAIRT_BIN = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang'
sys.path.insert(0, QAIRT_BIN)

from qti.aisw.converters import onnx as onnx_frontend
from qti.aisw.converters.common.converter_ir.op_graph_optimizations import IROptimizations
from qti.aisw.converters.backend.ir_to_qnn import QnnConverterBackend
from qti.aisw.converters.qnn_backend.custom_ops.op_factory import QnnCustomOpFactory
import runpy

mod = runpy.run_path(QAIRT_BIN + '/qnn-onnx-converter', run_name='not_main')
ONNXtoQNNArgParser = mod['ONNXtoQNNArgParser']

args = ONNXtoQNNArgParser().parse_args()
converter = onnx_frontend.OnnxConverterFrontend(args, custom_op_factory=QnnCustomOpFactory())
ir_graph = converter.convert()

# QNN backend overrides (verbatim from CLI main)
args.perform_axes_to_spatial_first_order = True
args.squash_box_decoder = True
args.match_caffe_ssd_to_tf = True
args.adjust_nms_features_dims = True
args.extract_color_transform = True
args.preprocess_roi_pool_inputs = True
args.unroll_lstm_time_steps = True
args.expand_gru_op_structure = True
args.unroll_gru_time_steps = True
args.inject_cast_for_gather = True
args.force_prune_cast_ops = False
args.align_matmul_ranks = True
args.handle_gather_negative_indices = True

optimizer = IROptimizations(args)
optimized = optimizer.optimize(ir_graph)

# ---- FIXUP: RmsNorm fp32 constant inputs -> main-input dtype ----
fixed = 0
nodes = optimized.list_nodes() if hasattr(optimized, 'list_nodes') else []
if not nodes:
    nodes = list(getattr(optimized, 'nodes_in_order', []))
print('FIXUP scanning %d nodes' % len(nodes), file=sys.stderr)
for node in nodes:
    op = getattr(node, 'op', None)
    tstr = str(getattr(op, 'type', ''))
    if 'rmsnorm' not in tstr.lower().replace('_', '') and not str(getattr(op, 'name', '')).startswith('rms_norm_'):
        continue
    try:
        main_buf = optimized.get_buffer(node.input_names[0])
        main_dt = main_buf.dtype
    except Exception as e:
        print('FIXUP skip (no main buf):', node.op.name, e, file=sys.stderr)
        continue
    for inp in node.input_names[1:]:
        try:
            prod = optimized.get_producer_node(inp)
            cop = getattr(prod, 'op', None)
            ten = getattr(cop, 'tensor', None)
        except Exception:
            continue
        if ten is None or not hasattr(ten, 'dtype'):
            continue
        buf = None
        try:
            buf = optimized.get_buffer(inp)
        except Exception:
            pass
        buf_dt = str(getattr(buf, 'dtype', ''))
        if ten.dtype == np.float32 or 'FLOAT_32' in buf_dt:
            print('FIXUP %s: const %s tensor=%s buf=%s -> %s' % (
                node.op.name, inp, ten.dtype, buf_dt, main_dt), file=sys.stderr)
            cop.tensor = ten.astype(np.float16)
            if buf is not None:
                try:
                    buf.dtype = main_dt
                except Exception as e:
                    print('FIXUP buf.dtype set failed:', inp, e, file=sys.stderr)
            fixed += 1
print('FIXUP done, constants fixed:', fixed, file=sys.stderr)

# ---- FIXUP2: any remaining fp32 constant op (probe: only the 4 embedding pieces) ----
# In quantized+input_list mode the embedding constant is NOT lazy -> add_tensor derives
# its dtype from the numpy tensor itself and stays fp32; the Gather output then mismatches
# the fp16 RMS_NORM weight (0x232 vs 0x216). Cast all fp32 constants to fp16 at IR level.
import qti.aisw.converters.qnn_backend.qnn_backend_base as _qbb0
_FP16_E = _qbb0.ir_graph.QNN_DATATYPE_FLOAT_16
c32 = 0
for node in nodes:
    op = getattr(node, 'op', None)
    ten = getattr(op, 'tensor', None)
    if ten is None or not hasattr(ten, 'dtype') or ten.dtype != np.float32:
        continue
    try:
        op.tensor = ten.astype(np.float16)
    except Exception as e:
        print('CONST32 cast fail:', getattr(op, 'name', '?'), e, file=sys.stderr)
        continue
    try:
        op.dtype = np.float16
    except Exception:
        pass  # dtype may be a read-only property derived from tensor
    try:
        buf = optimized.get_buffer(node.output_names[0])
        buf.dtype = _FP16_E
    except Exception as e:
        print('CONST32 buf dtype fail:', getattr(op, 'name', '?'), e, file=sys.stderr)
    c32 += 1
    print('CONST32 %s cast fp32->fp16' % getattr(op, 'name', '?')[:60], file=sys.stderr)
print('FIXUP2 done, fp32 constants cast:', c32, file=sys.stderr)

backend = QnnConverterBackend(args)

# Observation wrapper on add_tensor: count/name every fp32 tensor added with data
_orig_addt = type(backend).add_tensor
_at32 = []
def _at(self, node_name, tensor_name, *a, **k):
    tdt = k.get('tensor_data_type')
    if tdt == _FP32:
        _at32.append(str(tensor_name)[:70])
        print('ADD32 %s' % str(tensor_name)[:70], file=sys.stderr)
    return _orig_addt(self, node_name, tensor_name, *a, **k)
type(backend).add_tensor = _at

# Quantized mode auto-enables float_fallback (set from quantization encodings during
# get_ir_graph), which forces ALL float tensors to FLOAT_32 at the backend while IR
# activation buffers stay fp16 -> RMS_NORM same-dtype validation dies. Wrap
# process_float_datatype to temporarily neutralize the fallback flag so float tensors
# resolve to fp16 (the proven-passing configuration); quantized weights are unaffected.
_orig_pfd = type(backend).process_float_datatype
def _pfd(self, is_bias=False):
    old = getattr(self, 'qairt_converter_float_fallback', False)
    self.qairt_converter_float_fallback = False
    try:
        return _orig_pfd(self, is_bias)
    finally:
        self.qairt_converter_float_fallback = old
type(backend).process_float_datatype = _pfd

# The embedding (un-quantized float weight) is added via add_lazy_tensor whose default
# tensor_data_type is FLOAT_32 and which does NOT route through process_float_datatype;
# in quantized mode that yields an fp32 Gather output and kills the first RMS_NORM.
# Flip FLOAT_32 -> FLOAT_16 on the lazy path (quantized dtypes untouched).
import qti.aisw.converters.qnn_backend.qnn_backend_base as _qbb
_FP16 = _qbb.ir_graph.QNN_DATATYPE_FLOAT_16
_FP32 = _qbb.ir_graph.QNN_DATATYPE_FLOAT_32
_orig_lazy = type(backend).add_lazy_tensor
def _lz(self, *a, **k):
    if len(a) > 8:
        a = list(a)
        if a[8] == _FP32:
            a[8] = _FP16
            print('LAZY16 %s' % str(a[1] if len(a) > 1 else '?')[:60], file=sys.stderr)
    elif k.get('tensor_data_type') == _FP32:
        k['tensor_data_type'] = _FP16
        print('LAZY16 %s' % str(k.get('tensor_name', '?'))[:60], file=sys.stderr)
    return _orig_lazy(self, *a, **k)
type(backend).add_lazy_tensor = _lz

backend.save(optimized)
print('CONVERSION COMPLETE', file=sys.stderr)
