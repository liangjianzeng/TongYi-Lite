#!/usr/bin/env python3
# [npu-line] PAD-MASK probe, chunk 0 (worst case, 384 pad cols), real embeds, zero cache:
# our graph (ORT) vs HF layer-level (same am) vs HF full forward (rows 0..127).
# Decides whether the -1e4 pad columns split graph semantics from HF semantics on host.
import numpy as np
import torch
import onnxruntime as ort
from transformers import AutoModelForCausalLM, AutoTokenizer, DynamicCache

M = "/home/liang/models/minicpm5-2b"
ST = "/mnt/e/wsl_stage"
S, NC, NKV, HD, HID = 128, 512, 2, 128, 2048

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
tok = AutoTokenizer.from_pretrained(M)
prompt = ("请把下面这句话翻译成英文，并简要解释语法：今天天气很好，我们一起去公园散步吧。"
          "另外，用一句话总结量子计算的核心思想。")
ids = tok(prompt, add_special_tokens=True, return_tensors="pt")["input_ids"]
if ids.shape[1] < NC:
    pad = torch.full((1, NC - ids.shape[1]), tok.eos_token_id or 1, dtype=ids.dtype)
    ids = torch.cat([ids, pad], dim=1)
ids = ids[:, :NC]

acts = {}
model.model.layers[0].register_forward_hook(
    lambda m, i, o: acts.__setitem__("h", (o[0] if isinstance(o, tuple) else o).detach()))
with torch.no_grad():
    model.model(input_ids=ids, position_ids=torch.arange(88, 88 + NC).unsqueeze(0), use_cache=True)
hf_full0 = acts["h"]
if hf_full0.dim() == 3:
    hf_full0 = hf_full0[0]
hf_chunk0 = hf_full0[:S].float().numpy()

emb = model.model.embed_tokens(ids)[0].detach()
e = emb[:S]
hs_in = np.ascontiguousarray(e.numpy().T.reshape(HID, S).T[None]).astype(np.float16)
ctb = np.fromfile(f"{ST}/d2q_cos_table.raw", dtype="<f2").reshape(4, HD, S)
stb = np.fromfile(f"{ST}/d2q_sin_table.raw", dtype="<f2").reshape(4, HD, S)
cos = np.ascontiguousarray(ctb[0].T[None]).astype(np.float16)
sin = np.ascontiguousarray(stb[0].T[None]).astype(np.float16)
am = np.fromfile(f"{ST}/d2q_am_0.raw", dtype="<f2").reshape(1, 1, S, NC + S)
print("am stats: pad-col min", am[..., :NC - S].min(), "valid max", am[..., NC - S:].max(),
      "tri max", am[..., NC:].max())
kc = np.zeros((1, NKV, NC, HD), dtype=np.float16)
vc = np.zeros((1, NKV, NC, HD), dtype=np.float16)

sess = ort.InferenceSession(
    "/home/liang/models/mcp5_dec2_512_s128/mcp5_dec2p_l0.onnx",
    ort.SessionOptions(), providers=['CPUExecutionProvider'])
oh, ok, ov = sess.run(None, {"hs": hs_in, "kcache": kc, "vcache": vc,
                             "cos": cos, "sin": sin, "amask": am})
oh2 = oh[0].reshape(S, HID)

dc = DynamicCache()
dc.update(torch.from_numpy(kc.copy()), torch.from_numpy(vc.copy()), 0)
ly = model.model.layers[0]
with torch.no_grad():
    ol = ly(torch.from_numpy(hs_in), attention_mask=torch.from_numpy(am),
            position_ids=torch.arange(88, 88 + S).unsqueeze(0), past_key_values=dc,
            position_embeddings=(torch.from_numpy(cos), torch.from_numpy(sin)),
            use_cache=True, cache_position=torch.arange(NC, NC + S))
olh = (ol[0].reshape(S, HID) if ol[0].dim() == 3 else ol[0]).float().numpy()


def cs(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


print(f"chunk0: ORT|HFlayer {cs(oh2, olh):.4f}  ORT|HFfull {cs(oh2, hf_chunk0):.4f}  "
      f"HFlayer|HFfull {cs(olh, hf_chunk0):.4f}")
rowc = [cs(oh2[r], hf_chunk0[r]) for r in range(S)]
print(f"per-row ORT|HFfull: r0 {rowc[0]:.4f} r1 {rowc[1]:.4f} r127 {rowc[127]:.4f} "
      f"min {min(rowc):.4f} mean {np.mean(rowc):.4f}")
# mask-value sweep: does -1e4 vs -65504 vs -inf change ORT's attention?
for nm, val in (("-1e4", -1e4), ("-65504", -65504), ("-300", -300.0)):
    am2 = np.where(am < 0, np.float16(val), np.float16(0)).astype(np.float16)
    oh3, _, _ = sess.run(None, {"hs": hs_in, "kcache": kc, "vcache": vc,
                                "cos": cos, "sin": sin, "amask": am2})
    oh3 = oh3[0].reshape(S, HID)
    print(f"  mask {nm}: ORT|HFfull {cs(oh3, hf_chunk0):.4f}")
# HF with the same sweep (eager + our amask)
for nm, val in (("-1e4", -1e4), ("-65504", -65504), ("-300", -300.0)):
    am2 = np.where(am < 0, np.float16(val), np.float16(0)).astype(np.float16)
    dc2 = DynamicCache(); dc2.update(torch.from_numpy(kc.copy()), torch.from_numpy(vc.copy()), 0)
    with torch.no_grad():
        o2 = ly(torch.from_numpy(hs_in), attention_mask=torch.from_numpy(am2),
                position_ids=torch.arange(88, 88 + S).unsqueeze(0), past_key_values=dc2,
                position_embeddings=(torch.from_numpy(cos), torch.from_numpy(sin)),
                use_cache=True, cache_position=torch.arange(NC, NC + S))
    o2h = (o2[0].reshape(S, HID) if o2[0].dim() == 3 else o2[0]).float().numpy()
    print(f"  HF mask {nm}: HFlayer|HFfull {cs(o2h, hf_chunk0):.4f}")
print("PROBE79Q_DONE", flush=True)
