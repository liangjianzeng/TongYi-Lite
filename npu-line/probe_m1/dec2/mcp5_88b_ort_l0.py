#!/usr/bin/env python3
# [npu-line] ORT reference for the masked l0 probe (88): SAME bytes as device — d2q_kc_0
# (s,hd,kv file order) padded to 640, d2e_hs0 feed, cos/sin row 0, amask [512:640]=-1e4.
import numpy as np
import onnxruntime as ort

ST = "/mnt/e/wsl_stage"
NKV, HD, HID = 2, 128, 2048
NEG = np.float16(-1e4)

kc = np.fromfile(f"{ST}/dev/d2q_kc_0.raw", "<f2").reshape(512, HD, NKV).transpose(2, 0, 1)[None].copy()
vc = np.fromfile(f"{ST}/dev/d2q_vc_0.raw", "<f2").reshape(512, HD, NKV).transpose(2, 0, 1)[None].copy()
kcp = np.concatenate([kc, np.zeros((1, NKV, 128, HD), "<f2")], axis=2)
vcp = np.concatenate([vc, np.zeros((1, NKV, 128, HD), "<f2")], axis=2)
ct = np.fromfile(f"{ST}/d2_cos_table.raw", "<f2").reshape(-1, HD)
stt = np.fromfile(f"{ST}/d2_sin_table.raw", "<f2").reshape(-1, HD)
cos = np.ascontiguousarray(ct[0][None, None])
sin = np.ascontiguousarray(stt[0][None, None])
hs = np.fromfile(f"{ST}/d2e_hs0.raw", "<f2").reshape(1, 1, HID)
am = np.zeros((1, 1, 1, 641), "<f2")
am[0, 0, 0, 512:640] = NEG

s = ort.InferenceSession("/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx",
                         ort.SessionOptions(), providers=['CPUExecutionProvider'])
h, kn, vn = s.run(["h", "knew", "vnew"], {"hs": hs, "kcache": kcp, "vcache": vcp,
                                          "cos": cos, "sin": sin, "amask": am})


def cs(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


dh = np.fromfile(f"{ST}/g_dev_h640m.raw", "<f2")
dkn = np.fromfile(f"{ST}/g_dev_knew640m.raw", "<f2").reshape(HD, NKV)
print(f"h  dev|ORT  cos={cs(dh, h):.6f}   maxdiff={np.abs(dh.astype(np.float32)-h.astype(np.float32).ravel()).max():.4f}")
print(f"knew dev|ORT (kv,hd)->T cos={cs(dkn, kn.reshape(NKV, HD).T):.6f}")
print(f"knew dev|ORT raw-as(hd,kv) cos={cs(dkn, kn.ravel().reshape(HD, NKV)):.6f}")
