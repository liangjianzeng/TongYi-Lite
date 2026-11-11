#!/usr/bin/env python3
# [npu-line] G3: param_encodings generator for weight-only W8 (no activation calibration
# needed — the C21 no-op calibration path stays). QAIRT v1 encodings schema (NOT the
# [[scale,offset],...] list-of-lists — IROpGraph.embed_updatable_attributes indexes each
# enc element as a dict, op_graph.py:712 crashed TypeError before this was known).
# Proven-shape evidence: op_graph_optimizations uses len(enc[0]['scale']) (array form);
# libPyIrQuantizer.so strings carry enc_type/PER_TENSOR/PER_CHANNEL/per_channel_float_scale.
# Per-OUTPUT-channel symmetric int8 (IrQuantizer.ensureValidEncoding checks dim0 of the
# weight at quantize time; conv_w8 FIXUP5 stores packed FC weights OI [out,in]):
# scale = max|col|/127 over columns of the [in,out] onnx rhs, offset 0.
# Usage: python3 mcp5_93_gen_enc.py <model.onnx> <enc.json>
import json
import sys
import numpy as np
import onnx
from onnx import numpy_helper

onnx_path, out_path = sys.argv[1], sys.argv[2]
# optional 3rd arg: comma-separated weight whitelist (ablation — quantize only these)
only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None
m = onnx.load(onnx_path, load_external_data=True)

w_names = set()
for n in m.graph.node:
    if n.op_type in ("MatMul", "Gemm") and len(n.input) >= 2:
        w_names.add(n.input[1])
inits = {i.name: i for i in m.graph.initializer}
enc = {}
for name in sorted(w_names & set(inits)):
    if only is not None and name not in only:
        continue
    w = numpy_helper.to_array(inits[name])
    if w.ndim < 2:
        continue
    wf = w.astype(np.float32)
    # Per-channel axis = dim0 of the weight AT QUANTIZATION TIME. Combined with FIXUP5
    # (FC weight transposed to OI [out,in] for the packed-FC validator), that is
    # OUT-channels: cols of the [in,out] onnx rhs. (Evidence: untransposed [2048,130560]
    # -> "Expected 2048"; FIXUP5-transposed [130560,2048] -> "Expected 130560".)
    cols = wf.reshape(-1, wf.shape[-1])
    amax = np.abs(cols).max(axis=0)
    scale = np.maximum(amax / 127.0, 1e-8)
    # v1 schema (IROptimizations.get_default_enc/extract_encoding_dict,
    # op_graph_optimizations.py:892/1221): list = one dict PER CHANNEL; keys bitwidth
    # (int, NOT bw), is_symmetric (STRING "true"), dtype ("int"), scalar scale/offset.
    # min/max omitted -> computed from scale+bw symmetric (line ~1258).
    enc[name] = [{"bitwidth": 8, "dtype": "int", "is_symmetric": "true",
                  "scale": float(s), "offset": 0} for s in scale]
    print(f"ENC {name} shape={list(w.shape)} scale[min,max]="
          f"[{scale.min():.3e},{scale.max():.3e}]", flush=True)
# 'activation_encodings' key must exist even when empty: ConstantOp.update_param_quant_
# overrides indexes it unguarded (op_adapter.py:1409) while copying param -> activation.
json.dump({"activation_encodings": {}, "param_encodings": enc}, open(out_path, "w"))
print("GEN_ENC_DONE", len(enc), "tensors ->", out_path, flush=True)
