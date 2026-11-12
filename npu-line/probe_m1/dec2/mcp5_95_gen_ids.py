#!/usr/bin/env python3
# [npu-line] M2 bridge A1: canonical 512-token prompt ids, IDENTICAL protocol to
# mcp5_77_pre2_prep.py (same prompt, eos-pad to NC=512). Emits ids.raw int32 LE
# + ids.npy for the NPU-side re-prep (DEC_P0=0) and the GPU-side hyb_save/-load.
import numpy as np
import torch
from transformers import AutoTokenizer

M = "/home/liang/models/minicpm5-2b"
NC = 512
tok = AutoTokenizer.from_pretrained(M)
prompt = (
    "把下面这段技术文档完整翻译成英文，保持术语准确：大语言模型的推理过程分为预填充和解码两个阶段。"
    "预填充阶段并行处理全部提示词，计算注意力键值缓存，属于计算密集型负载；"
    "解码阶段逐个生成新词元，每步都要读取整个键值缓存，属于访存密集型负载。"
    "异构调度可以把预填充交给神经网络处理器，解码交给图形处理器，充分利用两者的算力与带宽差异。"
    "键值缓存的跨设备迁移需要注意量化格式、旋转位置编码的布局以及张量的内存排列顺序，"
    "任何一处布局错配都会导致后续生成迅速发散，因此必须用参考序列做端到端一致性验证。"
    "此外端侧部署还受内存驻留限制，进程编排与权重回收是必须解决的工程问题。"
    "请逐句翻译并保留段落结构。")
ids = tok(prompt, add_special_tokens=True, return_tensors="pt")["input_ids"]
if ids.shape[1] < NC:
    pad = torch.full((1, NC - ids.shape[1]), tok.eos_token_id or 1, dtype=ids.dtype)
    ids = torch.cat([ids, pad], dim=1)
ids = ids[:, :NC][0].to(torch.int32).numpy()
ids.tofile("/mnt/e/MyLLM_exp/hyb/ids.raw")
np.save("/mnt/e/MyLLM_exp/hyb/ids.npy", ids)
print("IDS_OK", NC, "real_tokens", int((ids != (tok.eos_token_id or 1)).sum()),
      "first10", ids[:10].tolist(), "eos", tok.eos_token_id)
