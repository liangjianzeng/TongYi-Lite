#!/usr/bin/env python3
# [npu-line] G3 tool calibration on the GREEN head: my expected-u8 stream generator must
# find its stream inside the head DLC params.bin (the packer's own truth). If nothing hits,
# the hypotheses (rounding/layout) are wrong and the red-layer scan is meaningless.
import json

import numpy as np
import onnx
import zipfile

HEAD = "/home/liang/models/mcp5_dec/mcp5_dec_l999head.onnx"
DLC = "/home/liang/w4sim/ctx_w8dec_l999head/w8dec_l999head"

ext = {e.key: e.value for e in (
    i for i in onnx.load_model(HEAD, load_external_data=False).graph.initializer
    if i.name == "val_0").__next__().external_data}
dims = [2048, 130560]  # as-stored IO from FIXUP5 log ([2048,130560] -> T -> OI)
n = 1
for d in dims:
    n *= d
w16 = np.fromfile("/home/liang/models/mcp5_dec/" + ext["location"], dtype="<f2",
                  count=n, offset=int(ext.get("offset", "0"))).reshape(dims)
print("val_0", w16.shape, flush=True)

j = json.load(open("/home/liang/head_enc.json"))["param_encodings"]["val_0"]
if isinstance(j, dict):
    sc = np.array([j["scale"]], np.float32)
else:
    sc = np.array([d["scale"] for d in j], np.float32)
print("scale len", len(sc), flush=True)

z = zipfile.ZipFile(DLC)
fp = z.open("model.params.bin")
fp._expected_crc = None
params = fp.read()
print("params", len(params), flush=True)


def qhalf(w, sc, mode):
    x = w / sc if sc.shape[0] == w.shape[1] else w / sc[:, None]
    if mode == "even":
        q = np.round(x)
    elif mode == "half":
        q = np.floor(np.abs(x) + 0.5) * np.sign(x)
    return np.clip(q, -128, 127).astype(np.int8)


def variants(u8):
    yield "rowmaj", u8.tobytes()
    out, in_ = u8.shape
    for t in (128, 256, 64):
        if out % t == 0:
            yield ("tile%d" % t,
                   np.ascontiguousarray(u8.reshape(out // t, t, in_).transpose(0, 2, 1)).tobytes())


for orient, arr in (("as-stored", w16), ("T", np.ascontiguousarray(w16.T))):
    a = arr.astype(np.float32)
    for mode in ("even", "half"):
        u8 = qhalf(a, sc, mode)
        for vn, blob in variants(u8):
            hit = params.find(blob)
            # also probe first 4096 bytes of stream to catch tail-region mismatches
            hit1 = params.find(blob[:4096])
            print("%-9s %-5s u8%s rowmajfind=%d head4k=%s" % (
                orient, mode, u8.shape, hit, hit1), flush=True)
print("HEADCAL_DONE")
