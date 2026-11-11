#!/usr/bin/env python3
# [npu-line] G3 diagnostic 2: minimal GQA attention block (k_proj linear + view/transpose
# + rope mul + cat-cache + batch-8 scores matmul + stack + PV matmul + head-merge
# reshape + o_proj) as onnx — reproduce the node_linear_1 FC batch-8 validator failure
# in a 60s loop instead of the full 42-layer graph.
import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

HID, NH, NKV, HD, NC = 2048, 16, 2, 128, 640
G = NH // NKV
rng = np.random.default_rng(0)


def T(name, arr):
    return numpy_helper.from_array(arr, name)


inp = lambda n, d: helper.make_tensor_value_info(n, TensorProto.FLOAT, d)
nodes, inits = [], []
# inputs: hs[1,1,HID], kcache[1,NKV,NC,HD], vcache, cos/sin[1,1,1,HD], q4[2,G,1,HD] (rope'd)
nodes.append(helper.make_node("Add", ["hs", "hs"], ["r1"], name="rms_proxy"))
for nm, shape, out in [("q", (HID, HID), "lin_q"), ("k", (HID, NKV * HD), "lin_k"),
                       ("v", (HID, NKV * HD), "lin_v")]:
    inits.append(T(f"w_{nm}", (rng.standard_normal(shape) * 0.02).astype(np.float32)))
    nodes.append(helper.make_node("MatMul", ["r1", f"w_{nm}"], [out], name=f"node_{nm}"))
nodes.append(helper.make_node("Reshape", ["lin_k", "shp_k"], ["k4"], name="k_view"))   # [1,1,NKV,HD]
inits.append(T("shp_k", np.array([1, 1, NKV, HD], np.int64)))
nodes.append(helper.make_node("Transpose", ["k4"], ["k3"], name="k_tr", perm=[0, 2, 1, 3]))  # [1,NKV,1,HD]
nodes.append(helper.make_node("Mul", ["k3", "cos"], ["kcos"], name="k_rope1"))
nodes.append(helper.make_node("Mul", ["kcos", "sin"], ["krot"], name="k_rope2"))
nodes.append(helper.make_node("Concat", ["kcache", "krot"], ["kfull"], name="k_cat", axis=2))  # [1,NKV,NC+1,HD]
nodes.append(helper.make_node("Reshape", ["lin_v", "shp_v"], ["v4"], name="v_view"))
inits.append(T("shp_v", np.array([1, 1, NKV, HD], np.int64)))
nodes.append(helper.make_node("Transpose", ["v4"], ["vfull"], name="v_tr", perm=[0, 2, 1, 3]))
# GQA: scores_i = q4[i] @ kfull[0,i]^T ; stack -> [2,G,1,NC+1]
for i in range(NKV):
    nodes.append(helper.make_node("Gather", ["kfull", f"idx{i}"], [f"ki_squeeze"], name=f"k_g{i}", axis=0))
    inits.append(T(f"idx{i}", np.array(0, np.int64)))
    nodes.append(helper.make_node("Squeeze", [f"ki_squeeze", f"sq{i}"], [f"ki"], name=f"k_sq{i}"))
    inits.append(T(f"sq{i}", np.array([0], np.int64)))
    nodes.append(helper.make_node("Transpose", [f"ki"], [f"kit"], name=f"k_t{i}", perm=[0, 2, 1]))  # [NKV? ...]
    # ki: [NKV? no: [NC+1, HD] after squeeze of dim0 from [1,NKV,NC+1,HD] gather->squeeze gives [NC+1,HD]? squeeze idx0 of [1,NC+1,HD]
    nodes.append(helper.make_node("Gather", ["q4", f"qi{i}"], [f"qi"], name=f"q_g{i}", axis=0))  # [G,1,HD]
    inits.append(T(f"qi{i}", np.array(i, np.int64)))
    nodes.append(helper.make_node("MatMul", [f"qi", f"kit"], [f"sc{i}"], name=f"node_scores_{i}"))  # [G,1,NC+1]
nodes.append(helper.make_node("Stack", ["sc0", "sc1"], ["scores"], name="stack_sc", axis=0))  # [2,G,1,NC+1]
nodes.append(helper.make_node("Softmax", ["scores"], ["probs"], name="sm", axis=-1))
for i in range(NKV):
    nodes.append(helper.make_node("Gather", ["probs", f"pi{i}"], [f"p{i}"], name=f"p_g{i}", axis=0))
    inits.append(T(f"pi{i}", np.array(i, np.int64)))
    nodes.append(helper.make_node("Gather", ["vfull", f"vi{i}"], [f"vi_s"], name=f"v_g{i}", axis=0))
    inits.append(T(f"vi{i}", np.array(0, np.int64)))
    nodes.append(helper.make_node("Squeeze", [f"vi_s", f"vsq{i}"], [f"vi"], name=f"v_sq{i}"))
    inits.append(T(f"vsq{i}", np.array([0], np.int64)))
    nodes.append(helper.make_node("MatMul", [f"p{i}", f"vi"], [f"ctx{i}"], name=f"node_pv_{i}"))  # [G,1,HD]
nodes.append(helper.make_node("Stack", ["ctx0", "ctx1"], ["ctxs"], name="stack_ctx", axis=0))  # [2,G,1,HD]
nodes.append(helper.make_node("Reshape", ["ctxs", "shp_o"], ["ao"], name="head_merge"))  # [1,NH*HD]
inits.append(T("shp_o", np.array([1, NH * HD], np.int64)))
inits.append(T("w_o", (rng.standard_normal((NH * HD, HID)) * 0.02).astype(np.float32)))
nodes.append(helper.make_node("MatMul", ["ao", "w_o"], ["attn"], name="node_o"))
nodes.append(helper.make_node("Add", ["hs", "attn"], ["h"], name="resid"))

graph = helper.make_graph(
    nodes, "gqa_smoke",
    [inp("hs", [1, 1, HID]), inp("kcache", [1, NKV, NC, HD]), inp("vcache", [1, NKV, NC, HD]),
     inp("cos", [1, NKV, 1, HD]), inp("sin", [1, NKV, 1, HD]), inp("q4", [NKV, G, 1, HD])],
    [inp("h", [1, 1, HID])], inits)
m = helper.make_model(graph)
m.opset_import[0].version = 15
onnx.save(m, "/home/liang/gqa_smoke.onnx")
print("GQA_SMOKE_SAVED", len(nodes), "nodes", flush=True)
