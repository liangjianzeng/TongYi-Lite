# -*- coding: utf-8 -*-
# Converter wrapper: replicate qnn-onnx-converter main() and, between optimizer and
# backend, fix the QAIRT 2.44 MATCH_RMSNORM bug: synthesized zero-beta / ones-weight
# constants are created fp32 while the pattern is fp16 -> QNN same-dtype validation
# rejects the fused RMS_NORM (0x232 != 0x216). Here IR buffers already carry dtypes,
# so the fixup is deterministic: for every RmsNorm op, cast fp32 constant inputs to
# the dtype of the op's main (first) input buffer.
import sys
import numpy as np

QAIRT_BIN = '/mnt/e/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang'
sys.path.insert(0, QAIRT_BIN)

from qti.aisw.converters import onnx as onnx_frontend
from qti.aisw.converters.common.converter_ir.op_graph_optimizations import IROptimizations
from qti.aisw.converters.backend.ir_to_qnn import QnnConverterBackend
from qti.aisw.converters.qnn_backend.custom_ops.op_factory import QnnCustomOpFactory
import runpy

# [C26] Optional MATMUL_TO_FC fold skip (W8_ALLOW_FC=0). Reality check (2026-11-11):
# the fold is REQUIRED for packing — the quantizer only packs FC/Conv weights (skip +
# encodings leaves the constant-fed MatMul graph squashed: "Total Params Count: 0").
# Keeping the fold (default W8_ALLOW_FC=1) + dict-schema param_encodings packs int8
# (DLC val_0 data_type 776 = SFIXED_POINT_8). The quantized-FC validator then wants OI
# weight layout -> FIXUP5 below. The "batch 8 != 1" validator death on partial encodings
# was root-caused to FIXUP5 gating on quantization_params membership (un-encoded FCs
# stayed IO) — fixed in [C28]: transpose by TYPE.
import os as _os0
if _os0.environ.get('W8_ALLOW_FC', '0') != '1':
    import qti.aisw.converters.common.converter_ir.op_graph_optimizations as _ogo
    _ama = _ogo.OptimizationTranslations.apply_method_to_graph
    def _skip_matmul_to_fc(*a, **k):
        if len(a) >= 1 and a[0] == "MATMUL_TO_FC":
            print('[C26] skipped MATMUL_TO_FC fold (kept MatMul for W8A16-float)',
                  file=sys.stderr)
            return
        return _ama(*a, **k)
    _ogo.OptimizationTranslations.apply_method_to_graph = _skip_matmul_to_fc

mod = runpy.run_path(QAIRT_BIN + '/qnn-onnx-converter', run_name='not_main')
ONNXtoQNNArgParser = mod['ONNXtoQNNArgParser']

args = ONNXtoQNNArgParser().parse_args()
# [C22] native cpp/bin writer (qnn_modeltools) segfaults on this quantized graph at
# "Saving QNN Model..."; no-pack rerun crashed identically. Export DLC instead — the
# save_to_dlc path (python, ir_to_dlc.py) is a separate writer and DLC -> context
# binary is the preferred device deployment form anyway (skips ndk-build).
# UPDATE 2026-11-11: DLC-path layers are device-RED at ZERO quantization too (w8offfc trio)
# while the DLC tensor content is provably clean (7 FC s8 OI, attention all f16, no f32);
# 92-line cpp/bin -> model.so -> ctxgen --model is GREEN with the same ONNX. Poison
# suspected in DLC compose/prepare, so W8_EXPORT_FMT=cpp re-arms the native writer
# (FIXUP4's honest constants may already cure [C22]'s dtype-size overrun).
args.export_format = _os0.environ.get('W8_EXPORT_FMT', 'dlc')
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
# bisect env switches (poison hunt 2026-11-11): W8_NO_FIXUP/_lz/_pfd=1 disable each patch
nodes = optimized.list_nodes() if hasattr(optimized, 'list_nodes') else []
if not nodes:
    nodes = list(getattr(optimized, 'nodes_in_order', []))
print('FIXUP scanning %d nodes' % len(nodes), file=sys.stderr)
for node in nodes if _os0.environ.get('W8_NO_FIXUP', '0') != '1' else []:
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

# ---- FIXUP4: honest data for fake-fp32 lazy constants ----
# [C25] gdb regs: memmove reads PAST the end of an mmap (rsi=last page, rdx=4095 tail).
# Root cause: IR lazy constants carry a placeholder FLOAT_32 dtype while the external
# files hold fp16 data (v4.onnx is fp16). Writers compute read sizes from the dtype ->
# 2x overrun -> SIGSEGV at mmap boundary. The quantizer also requires FLOAT_32 to
# quantize. Fix: read the TRUE fp16 bytes from the external file and materialize
# honest arrays: quantizable weights -> real fp32 (upcast); non-weight consts -> fp16.
import qti.aisw.converters.qnn_backend.qnn_backend_base as _qbb0
from qti.aisw.converters.common.converter_ir import op_adapter as _oa
import onnx as _onnx
from onnx.external_data_helper import uses_external_data as _uext
_W_OPS = {_oa.MatMulOp.TRANSLATION_KEY, _oa.FullyConnectedOp.TRANSLATION_KEY,
          _oa.Conv2dOp.TRANSLATION_KEY, _oa.Conv3dOp.TRANSLATION_KEY,
          _oa.DepthwiseConv2dOp.TRANSLATION_KEY, _oa.TransposeConv2dOp.TRANSLATION_KEY,
          _oa.TransposeConv3dOp.TRANSLATION_KEY, _oa.LstmOp.TRANSLATION_KEY}
_FP16_E = _qbb0.ir_graph.QNN_DATATYPE_FLOAT_16
_FP32_E = _qbb0.ir_graph.QNN_DATATYPE_FLOAT_32

import os as _os
_onnx_base = _os.path.dirname(_os.path.realpath(args.input_network))
_ext_meta = {}  # name -> (file, offset, dims)
_om = _onnx.load(args.input_network, load_external_data=False)
def _reg(name, t):
    if _uext(t):
        loc = next((e.value for e in t.external_data if e.key == 'location'), None)
        off = next((e.value for e in t.external_data if e.key == 'offset'), None) or '0'
        if loc and t.data_type == 10:  # fp16 only
            _ext_meta[name] = (_os.path.join(_onnx_base, loc), int(off), list(t.dims))
for _i in _om.graph.initializer:
    _reg(_i.name, _i)
def _walk_consts(g):
    for _n in g.node:
        if _n.op_type == 'Constant':
            for _a in _n.attribute:
                if _a.t is not None and _n.output:
                    _reg(_n.output[0], _a.t)
        for _a2 in _n.attribute:
            if _a2.g is not None:
                _walk_consts(_a2.g)
_walk_consts(_om.graph)
del _om
print('EXTMETA fp16 external tensors: %d' % len(_ext_meta), file=sys.stderr)

c_w = c_f = 0
for node in nodes if _os.environ.get('W8_NO_FIXUP4', '0') != '1' else []:
    op = getattr(node, 'op', None)
    name = getattr(op, 'name', '?')
    meta = _ext_meta.get(name)
    if meta is None:
        continue  # only external-fp16 constants need honest materialization
    is_weight = False
    try:
        for cons in optimized.get_buffer(node.output_names[0]).consumers:
            if str(getattr(cons.op, 'type', '')) in _W_OPS:
                is_weight = True
                break
    except Exception:
        pass
    fpath, off, dims = meta
    try:
        n_elem = 1
        for d in dims:
            n_elem *= d
        arr16 = np.fromfile(fpath, dtype='<f2', count=n_elem, offset=off).reshape(dims)
    except Exception as e:
        print('FIXUP4 read fail %s: %s' % (name[:60], e), file=sys.stderr)
        continue
    try:
        buf = optimized.get_buffer(node.output_names[0])
        if is_weight:
            op.tensor = arr16.astype(np.float32)  # honest fp32 -> quantizer + writer safe
            try:
                op.dtype = np.float32
            except Exception:
                pass
            buf.dtype = _FP32_E
            c_w += 1
            if c_w <= 5 or c_w % 50 == 0:
                print('FIXUP4-W %s -> real fp32 (%d elems)' % (name[:50], n_elem), file=sys.stderr)
        else:
            op.tensor = arr16  # honest fp16
            try:
                op.dtype = np.float16
            except Exception:
                pass
            buf.dtype = _FP16_E
            c_f += 1
            print('FIXUP4-F %s -> real fp16' % name[:50], file=sys.stderr)
    except Exception as e:
        print('FIXUP4 assign fail %s: %s' % (name[:60], e), file=sys.stderr)
print('FIXUP4 done: weights_real_fp32=%d floats_real_fp16=%d' % (c_w, c_f), file=sys.stderr)

# ---- FIXUP5: FC weight orientation for the QUANTIZED HTP kernel ----
# [C27] matmul_to_fc keeps weights IO under SpatialLastAxisOrder (fold comment "FC weight
# shape is IO in spatial-last axis order", and transpose_in1 is False for ONNX MatMul so
# transpose_weight is skipped). The fp16 FC validator accepts IO, but the packed W8 FC
# validator derives n from the LAST weight dim -> "In[0] was not reshapable to [batch, n]
# ... activation dims 2048 multiple of n 130560" (0xc26/3110). Transpose every rank-2 FC
# weight constant (that has param encodings) to OI [out,in]; per-channel scale count
# (= in-features) matches the last dim either way (ensureValidEncoding said 2048).
c_t = 0
for node in nodes if _os0.environ.get('W8_NO_FIXUP5', '0') != '1' else []:
    op = getattr(node, 'op', None)
    if op is None or str(getattr(op, 'type', '')) != str(_oa.FullyConnectedOp.TRANSLATION_KEY):
        continue
    if len(node.input_names) < 2:
        continue
    try:
        wbuf = optimized.get_buffer(node.input_names[1])
        wnode = wbuf.producer
        wop = wnode.op
        arr = wop.tensor
    except Exception as e:
        print('FIXUP5 skip %s: %s' % (getattr(op, 'name', '?'), e), file=sys.stderr)
        continue
    if arr is None or getattr(arr, 'ndim', 0) != 2:
        continue
    if getattr(wop, 'tensor', None) is None or str(getattr(wop, 'type', '')).lower().find('constant') < 0:
        continue
    # [C28] transposition must be BY TYPE, not by quantization_params membership: with
    # partial --quantization_overrides the un-encoded FCs drop out of quantization_params,
    # stay IO, and the HTP FC master-op validator (strict batch check applies to fp16 FCs
    # too) dies on them: "Mismatch in batch between inputs and outputs. 8 != 1" (k_proj
    # IO last-dim 256 -> batch 2048/256) on an op OTHER than the encoded one (0xc26/3110).
    # OI is safe for fp16 FCs as well (batch = in/in = 1), matching the fp16 baseline.
    print('FIXUP5 %s: weight %s %s -> %s' % (op.name, node.input_names[1][:40],
                                              list(arr.shape), list(arr.T.shape)), file=sys.stderr)
    wop.tensor = np.ascontiguousarray(arr.T)
    try:
        wbuf.shape = list(arr.T.shape)
    except Exception as e:
        print('FIXUP5 buf.shape fail:', e, file=sys.stderr)
    c_t += 1
print('FIXUP5 done, FC weights transposed to OI:', c_t, file=sys.stderr)

backend = QnnConverterBackend(args)

# [C21]: activation calibration (generate_activations) is no-op'd via source patch on
# qnn_quantizer.py — the CPU calibration runtime segfaults deterministically on this
# graph. Natural flow retained: quantize_params(True) -> (no-op activations) ->
# quantize_params(False) packs weights to 4-bit; un-encoded activations stay fp16 (A16).

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
if _os.environ.get('W8_NO_PFD', '0') != '1':
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
if _os.environ.get('W8_NO_LZ', '0') != '1':
    type(backend).add_lazy_tensor = _lz

backend.save(optimized)
print('CONVERSION COMPLETE', file=sys.stderr)
