# -*- coding: utf-8 -*-
# Route A: Spark-X2.6-4B prefill static graph re-export (seq=512), NPU-friendly.
# - rope constant-folded per layer type (full prf=0.25 theta=5e6 -> R=64; sliding prf=1.0 theta=1e4 -> R=256)
# - GQA 16:4 via merged-view matmul (no Expand/Tile, no broadcast matmul)
# - causal mask baked as constant, pre-tiled to merged (s*4+p) row layout
# - headwise sigmoid gate as broadcast Mul
# - fp16 residual stream (NPU-friendly), fp32 softmax + fp32 RMSNorm internals (matches reference)
# - input int32 [1,512]
# Run in WSL2: python3 with torch 2.6 cu124 + transformers 4.57.1
import os, sys, math, traceback
import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

MP = '/mnt/d/MyLLM/models/spark-x26-4b/hf'
OUT = '/mnt/e/MyLLM_exp/spark_prefill_v2.onnx'
REF = '/mnt/e/MyLLM_exp/m1_ref.npz'
SEQ = 512
os.environ['PYTHONIOENCODING'] = 'utf-8'

print('loading fp16 model on cuda...', flush=True)
from transformers import AutoModelForCausalLM
model = AutoModelForCausalLM.from_pretrained(MP, trust_remote_code=True, torch_dtype=torch.float16)
model.eval()
model.config.use_cache = False
cfg = model.config
H = cfg.hidden_size            # 2560
NH = cfg.num_attention_heads   # 16
NKV = cfg.num_key_value_heads  # 4
HD = cfg.head_dim              # 256
NL = cfg.num_hidden_layers     # 36
GRP = NH // NKV                # 4
QD = NH * HD                   # 4096
KVD = NKV * HD                 # 1024
SCALE = 1.0 / math.sqrt(HD)
print(f'H={H} NH={NH} NKV={NKV} HD={HD} NL={NL} tie={cfg.tie_word_embeddings}', flush=True)

# ---- rope constants per layer type ----
def rope_cs(theta, prf):
    rhd = int(HD * prf)
    inv = 1.0 / (theta ** (torch.arange(0, rhd, 2, dtype=torch.float32) / rhd))
    pos = torch.arange(SEQ, dtype=torch.float32)
    fr = torch.outer(pos, inv)
    fr = torch.cat([fr, fr], dim=-1)  # [SEQ, rhd]
    return fr.cos(), fr.sin()

lt_cfg = {}
for lt in set(cfg.layer_types):
    rp = cfg.rope_parameters[lt]
    lt_cfg[lt] = rope_cs(float(rp['rope_theta']), float(rp['partial_rotary_factor']))
    print(lt, 'rope dim', lt_cfg[lt][0].shape, flush=True)

# ---- causal mask, merged row layout row = s*GRP + p ----
base = torch.full((SEQ, SEQ), -30000.0)
base = torch.triu(base, diagonal=1)  # upper triangle -30000
mask_merged = base.unsqueeze(1).repeat(1, GRP, 1).reshape(SEQ * GRP, SEQ)  # [2048,512], row=s*4+p
assert mask_merged[3, 5] == -30000.0 and mask_merged[8, 1] == 0.0  # row3=s0p3 q5 masked; row8=s2p0 q1 unmasked

def apply_rope(x, cos, sin):
    # x [B,H,S,D] fp16, cos/sin [S,R] fp32 -> rope in fp32
    rhd = cos.shape[-1]
    xf = x.float()
    c = cos[None, None]
    s = sin[None, None]
    if rhd == x.shape[-1]:
        half = rhd // 2
        x1 = xf[..., :half]; x2 = xf[..., half:]
        rot = torch.cat((-x2, x1), dim=-1)
        y = xf * c + rot * s
    else:
        xr = xf[..., :rhd]; xp = xf[..., rhd:]
        half = rhd // 2
        x1 = xr[..., :half]; x2 = xr[..., half:]
        rot = torch.cat((-x2, x1), dim=-1)
        yr = xr * c + rot * s
        y = torch.cat((yr, xp), dim=-1)
    return y.to(x.dtype)

class PrefillStatic(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        for lt, (c, s) in lt_cfg.items():
            self.register_buffer('cos_' + lt, c.contiguous())
            self.register_buffer('sin_' + lt, s.contiguous())
        self.register_buffer('mask', mask_merged.contiguous())

    def attn(self, sa, x, lt):
        cos = getattr(self, 'cos_' + lt); sin = getattr(self, 'sin_' + lt)
        qkv = sa.q_k_v_proj(x)  # [1,512,6144]
        q = qkv[..., :QD]
        k = qkv[..., QD:QD + KVD]
        v = qkv[..., QD + KVD:]
        q = q.view(1, SEQ, NH, HD).transpose(1, 2)   # [1,16,512,256]
        k = k.view(1, SEQ, NKV, HD).transpose(1, 2)  # [1,4,512,256]
        v = v.view(1, SEQ, NKV, HD).transpose(1, 2)
        q = apply_rope(q, cos, sin)
        k = apply_rope(k, cos, sin)
        # merge (s,p): row = s*GRP + p
        qm = q.view(1, NKV, GRP, SEQ, HD).permute(0, 1, 3, 2, 4).reshape(1, NKV, SEQ * GRP, HD)
        kk = k.transpose(-1, -2)  # [1,4,256,512]
        sc = torch.matmul(qm, kk) * SCALE  # [1,4,2048,512]
        sc = sc + self.mask  # [1,1,2048,512] broadcast
        p = F.softmax(sc.float(), dim=-1).to(x.dtype)
        o = torch.matmul(p, v)  # [1,4,2048,256]
        o = o.view(1, NKV, SEQ, GRP, HD).permute(0, 1, 3, 2, 4).reshape(1, NH, SEQ, HD)
        o = o.transpose(1, 2)  # [1,512,16,256]
        gate = sa.g_proj(x)  # [1,512,16]
        gate = torch.sigmoid(gate.float()).to(x.dtype).unsqueeze(-1)  # [1,512,16,1]
        o = o * gate
        o = o.reshape(1, SEQ, QD)
        return sa.out_proj(o)

    def forward(self, ids):
        m = self.m.model
        h = m.embedding(ids)  # [1,512,2560] fp16
        for i, layer in enumerate(m.layers):
            lt = cfg.layer_types[i]
            sa = layer.self_attn
            resid = h
            x = layer.input_layernorm(h)
            h = resid + self.attn(sa, x, lt)
            resid = h
            x = layer.post_attention_layernorm(h)
            h = resid + layer.mlp(x)
        h = m.norm(h)
        return F.linear(h, m.embedding.weight)  # tied lm_head

torch.manual_seed(0)
ids32 = torch.randint(16, cfg.vocab_size, (1, SEQ), dtype=torch.int32)
ids64 = ids32.long()

wrapper = PrefillStatic(model).eval()

# ---- numeric validation vs reference forward ----
print('reference forward...', flush=True)
with torch.no_grad():
    ref = model(input_ids=ids64).logits  # [1,512,131072] fp16
    ours = wrapper(ids32)
print('ref', ref.shape, ref.dtype, 'ours', ours.shape, ours.dtype, flush=True)
diff = (ours.float() - ref.float()).abs()
print(f'maxabs={diff.max().item():.5f} meanabs={diff.mean().item():.6f}', flush=True)
rl = ref[0, -1].float(); ol = ours[0, -1].float()
print('last argmax ref/ours:', rl.argmax().item(), ol.argmax().item(), flush=True)
t5r = set(rl.topk(5).indices.tolist()); t5o = set(ol.topk(5).indices.tolist())
print('last top5 overlap:', len(t5r & t5o), flush=True)
np.savez(REF, ids=ids32.numpy().astype(np.int32),
         ref_last=rl.cpu().numpy().astype(np.float32),
         our_last=ol.cpu().numpy().astype(np.float32))
print('saved ref npz', flush=True)
del ref, ours, diff
torch.cuda.empty_cache()

# ---- export ----
print('exporting...', flush=True)
try:
    torch.onnx.export(
        wrapper, (ids32,), OUT,
        input_names=['input_ids'], output_names=['logits'],
        opset_version=17, do_constant_folding=True, dynamo=False)
    print('EXPORT_OK', OUT, flush=True)
except Exception:
    traceback.print_exc()
    print('EXPORT_FAIL', flush=True)
    raise SystemExit(1)

# ---- graph audit ----
import onnx
m = onnx.load(OUT, load_external_data=False)
ops = {}
bad = []
for n in m.graph.node:
    ops[n.op_type] = ops.get(n.op_type, 0) + 1
    if n.op_type in ('Expand', 'Tile'):
        bad.append(n.name)
print('OP_HISTOGRAM', sorted(ops.items(), key=lambda kv: -kv[1]), flush=True)
print('EXPAND_TILE_NODES', bad, flush=True)
i64 = [init.name for init in m.graph.initializer if init.data_type == onnx.TensorProto.INT64]
print('INT64_INITIALIZERS', i64, flush=True)
gi = m.graph.input[0]
print('GRAPH_INPUT', gi.name, gi.type.tensor_type.elem_type,
      [d.dim_value for d in gi.type.tensor_type.shape.dim], flush=True)
print('num_nodes', len(m.graph.node), flush=True)
print('ALL_DONE', flush=True)
