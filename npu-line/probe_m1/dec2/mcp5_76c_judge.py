#!/usr/bin/env python3
# [npu-line] judge the hs-layout variant probe: device knew/vnew/h vs ORT refs.
# t=0 fed hs natural (s,hid); t=1 fed hs declared (hid,s). h device bytes are declared
# [1,2048,128] order -> compare vs both natural and T readings of the ORT ref.
import numpy as np

ST = "/mnt/e/wsl_stage"


def cs(a, b):
    a = a.astype(np.float32).ravel()
    b = b.astype(np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


S, HID = 128, 2048
rk = np.fromfile(f"{ST}/g_ref_knew.raw", dtype="<f2")
rv = np.fromfile(f"{ST}/g_ref_vnew.raw", dtype="<f2")
rh = np.fromfile(f"{ST}/g_ref_h.raw", dtype="<f2")
rh_T = rh.reshape(S, HID).T.ravel()
for t in (0, 1):
    dk = np.fromfile(f"{ST}/dev/g_dev_knew_{t}.raw", dtype="<f2")
    dv = np.fromfile(f"{ST}/dev/g_dev_vnew_{t}.raw", dtype="<f2")
    dh = np.fromfile(f"{ST}/dev/g_dev_h_{t}.raw", dtype="<f2")
    print(f"t={t} ({'natural' if t == 0 else 'declared-T'} hs): "
          f"knew {cs(dk, rk):.4f}  vnew {cs(dv, rv):.4f}  "
          f"h|nat {cs(dh, rh):.4f}  h|T {cs(dh, rh_T):.4f}")

# knew is wrong while vnew==1.0 at t=1 -> ONLY the rope path (cos/sin) can split k from v.
# Enumerate plausible cos/sin byte readings, run ORT, match device knew by cos.
import torch
import onnxruntime as ort

OUT = "/home/liang/models/mcp5_dec2_512_s128"
S, NC, NKV, HD, HID = 128, 512, 2, 128, 2048
torch.manual_seed(42)
hs_t = (torch.randn(1, S, HID) * 0.5).half()          # same draw as 76b
ct = np.fromfile(f"{ST}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
stt = np.fromfile(f"{ST}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
sess = ort.InferenceSession(f"{OUT}/mcp5_dec2p_l0.onnx", ort.SessionOptions(),
                            providers=['CPUExecutionProvider'])
zk = np.zeros((1, NKV, NC, HD), dtype="<f2")
dk1 = np.fromfile(f"{ST}/dev/g_dev_knew_1.raw", dtype="<f2")
cands = {
    "natural (s,hd)": (ct[:S], stt[:S]),
    "cos<->sin swapped": (stt[:S], ct[:S]),
    "rows reversed": (ct[:S][::-1], stt[:S][::-1]),
    "T-in-rows (read (hd,s))": (ct[:S].T.copy(), stt[:S].T.copy()),
    "shift -1 row": (np.roll(ct[:S], -1, 0), np.roll(stt[:S], -1, 0)),
    "shift +1 row": (np.roll(ct[:S], 1, 0), np.roll(stt[:S], 1, 0)),
    "zeros": (np.zeros((S, HD), "<f2"), np.zeros((S, HD), "<f2")),
}
for nm, (ca, sa) in cands.items():
    feed = {"hs": hs_t.numpy(), "kcache": zk, "vcache": zk,
            "cos": np.ascontiguousarray(ca[None]), "sin": np.ascontiguousarray(sa[None])}
    _, ok_c, _ = sess.run(None, feed)
    print(f"  k-cand {nm:24s}: cos(dev, ort) = {cs(dk1, ok_c.astype('<f2').ravel()):.4f}")
