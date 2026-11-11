#!/usr/bin/env python3
# [npu-line] G3: expected-u8 stream forensics. Quantize layer-0 FC weight constants with
# the enc scales (both scale-axis hypotheses: dim0-as-stored IO, and out-channels after
# FIXUP5 OI), emit row/tile-major variants, then search:
#   A) the DLC model.params.bin (converter ground truth: generator sanity)
#   B) green head ctx (positive control: compose preserves its pack)
#   C) red layer ctxs (discriminate compose-corruption vs byte-faithful)
import json
import sys

import numpy as np
import onnx
from onnx import numpy_helper
from onnx.external_data_helper import load_external_data_for_tensor

MODELS = "/home/liang/models/mcp5_dec2_640"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
LAYER = int(sys.argv[1]) if len(sys.argv) > 1 else 0
WEIGHTS = {"val_13": 256, "val_20": 256, "val_112": 6144}  # small/medium FCs


def load_init(name):
    # read external fp16 bytes directly (pitfall: onnx's regular-file check flakes here;
    # FIXUP4 reads the same way at build time)
    m = onnx.load_model(f"{MODELS}/mcp5_nc640_l{LAYER}.onnx", load_external_data=False)
    for i in m.graph.initializer:
        if i.name != name:
            continue
        ext = {e.key: e.value for e in i.external_data}
        loc = ext["location"]
        off = int(ext.get("offset", "0"))
        dims = [int(x) for x in i.dims]
        n = 1
        for d in dims:
            n *= d
        return np.fromfile(f"{MODELS}/{loc}", dtype="<f2", count=n, offset=off).reshape(dims)
    raise KeyError(name)


def enc_pair(path, name):
    j = json.load(open(path))["param_encodings"][name]
    if isinstance(j, dict):  # single-dict form
        return np.array([j["scale"]], np.float32), np.array([j["offset"]], np.float32)
    return (np.array([d["scale"] for d in j], np.float32),
            np.array([d["offset"] for d in j], np.float32))


def q8(w, sc):
    # w: [out, in] fp32; sc: per-row (out) scale. ROUNDING = round-half-away-from-zero
    # (calibrated on green head: mcp5_93_headcal.py T+half rowmaj found@0; np.round's
    # banker rounding MISSES).
    if sc.shape[0] == w.shape[0]:
        x = w / sc[:, None]
    elif sc.shape[0] == w.shape[1]:
        x = w / sc[None, :]
    else:
        raise ValueError("scale len %d vs w %s" % (sc.shape[0], w.shape))
    q = np.floor(np.abs(x) + 0.5) * np.sign(x)
    return np.clip(q, -128, 127).astype(np.int8)


def variants(u8):
    out, in_ = u8.shape
    for t in (128, 64, 256):
        if out % t == 0:
            yield ("tile%d" % t,
                   np.ascontiguousarray(u8.reshape(out // t, t, in_).transpose(0, 2, 1)).tobytes())
    yield "rowmaj", u8.tobytes()


enc = "/home/liang/l%d_enc.json" % LAYER
blobs = {}
try:
    import zipfile
    z = zipfile.ZipFile(f"/home/liang/w4sim/ctx_w8nc640_l{LAYER}/w8nc640_l{LAYER}")
    fp = z.open("model.params.bin")
    fp._expected_crc = None
    blobs["params"] = fp.read()
except Exception as e:
    print("params load fail:", e)
for tag in ["w8dec_l999head", "w8nc640_l0", "w8cpp_l0"]:
    try:
        blobs[tag] = open(f"{SERVE}/{tag}_ctx.bin", "rb").read()
    except Exception as e:
        print(tag, "open fail", e)

for wname in WEIGHTS:
    try:
        w16 = load_init(wname)
    except Exception as e:
        print(wname, "INIT FAIL", e)
        continue
    sc, _ = enc_pair(enc, wname)
    print("%s init %s enc_scale_len=%d" % (wname, w16.shape, sc.shape[0]), flush=True)
    w = w16.astype(np.float32)
    for orient, arr in (("as-stored", w), ("T", np.ascontiguousarray(w.T))):
        try:
            u8 = q8(arr, sc)
        except ValueError as e:
            print("   ", orient, "skip", e)
            continue
        for vn, blob in variants(u8):
            hits = {b: blobs[b].find(blob) for b in blobs}
            found = {b: h for b, h in hits.items() if h >= 0}
            found4k = {b: blobs[b].find(blob[:4096]) for b in blobs}
            found4k = {b: h for b, h in found4k.items() if h >= 0}
            print("   %-9s %-6s u8%s found_in=%s head4k=%s" % (
                orient, vn, u8.shape, found or "{}", found4k or "{}"), flush=True)
print("KNVEC_SCAN_DONE")
