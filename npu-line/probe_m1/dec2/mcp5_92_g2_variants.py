#!/usr/bin/env python3
# [npu-line] G2 prefill-mask A/B: post-export ONNX surgery on dec2p_l0 (masked chunked
# prefill, [2,8,128,640] scores + [1,1,128,640] amask broadcast-add feeding softmax).
# dynamo folds a physical expand back to broadcast (MASK_FULL dead), so inject HERE —
# after export, converter sees the graph as written.
# Variants (tag-suffixed copies, baseline untouched):
#   dec2pt_l0  Tile(amask,[2,8,1,1]) -> full-shape Add (no HTP broadcast path)
#   dec2pc_l0  amask -> initializer (const mask, converter may optimize add w/ const)
#   dec2pn_l0  amask+Add removed (floor reference for the 10ms unmasked claim)
# Usage: python3 mcp5_92_g2_variants.py [tile|const|nomask|all]
import os
import sys
import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto

D = "/home/liang/models/mcp5_dec2_512_s128"
SRC = f"{D}/mcp5_dec2p_l0.onnx"
S, NC, NKV, G = 128, 512, 2, 8
NEG = np.float16(-1e4)


def load():
    m = onnx.load(SRC, load_external_data=False)
    add3 = next(n for n in m.graph.node if n.op_type == "Add" and "amask" in n.input)
    return m, add3


def drop_input(m, name):
    for i in reversed([i for i, x in enumerate(m.graph.input) if x.name == name]):
        del m.graph.input[i]


def variant_tile():
    m, add3 = load()
    rep = numpy_helper.from_array(np.array([NKV, G, 1, 1], dtype=np.int64), "am_reps")
    tile = helper.make_node("Tile", ["amask", "am_reps"], ["am_tile"], name="am_tile_op")
    m.graph.node.insert(list(m.graph.node).index(add3), tile)
    m.graph.initializer.append(rep)
    add3.input[1] = "am_tile"
    onnx.save(m, f"{D}/mcp5_dec2pt_l0.onnx")
    print("TILE_OK nodes=", len(m.graph.node), flush=True)


def variant_const():
    m, add3 = load()
    am = np.zeros((NKV, G, S, NC + S), np.float16)   # value-irrelevant for timing;
    am[:, :, :, NC:] = np.triu(np.full((S, S), NEG), 1)  # export-pattern full-window
    m.graph.initializer.append(numpy_helper.from_array(am, "amask"))
    drop_input(m, "amask")
    onnx.save(m, f"{D}/mcp5_dec2pc_l0.onnx")
    print("CONST_OK", flush=True)


def variant_nomask():
    m, add3 = load()
    scores = add3.input[0]
    for n in m.graph.node:
        n.input[:] = [scores if x == "add_3" else x for x in n.input]
    for o in list(m.graph.output):
        o.name = scores if o.name == "add_3" else o.name
    m.graph.node.remove(add3) if hasattr(m.graph.node, "remove") else \
        m.graph.node.__delitem__(list(m.graph.node).index(add3))
    drop_input(m, "amask")
    onnx.save(m, f"{D}/mcp5_dec2pn_l0.onnx")
    print("NOMASK_OK", flush=True)


def variant_tile_all():
    # IN-PLACE on the staged mcp5_dec2p_l{k}.onnx copies (build TAG=dec2p gives the ctx the
    # graph name manifest_pre2_* expects). Idempotent: re-tiled files lack the broadcast
    # Add-with-amask (input already rewired to am_tile) and are skipped.
    for k in range(42):
        path = f"{D}/mcp5_dec2p_l{k}.onnx"
        m = onnx.load(path, load_external_data=False)
        cands = [n for n in m.graph.node if n.op_type == "Add" and "amask" in n.input]
        if not cands:
            print(f"TILE_SKIP l{k} (already tiled)", flush=True)
            continue
        add3 = cands[0]
        rep = numpy_helper.from_array(np.array([NKV, G, 1, 1], dtype=np.int64), "am_reps")
        tile = helper.make_node("Tile", ["amask", "am_reps"], ["am_tile"], name="am_tile_op")
        m.graph.node.insert(list(m.graph.node).index(add3), tile)
        m.graph.initializer.append(rep)
        add3.input[1] = "am_tile"
        onnx.save(m, path)
        print(f"TILE_OK l{k}", flush=True)


sel = sys.argv[1] if len(sys.argv) > 1 else "all"
if sel == "tileall":
    variant_tile_all()
elif sel in ("tile", "all"):
    variant_tile()
if sel in ("const", "all"):
    variant_const()
if sel in ("nomask", "all"):
    variant_nomask()
