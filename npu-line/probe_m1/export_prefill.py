# -*- coding: utf-8 -*-
# NPU M1: Spark-X2.6-4B prefill static graph export (seq=512, no KV, logits out)
# SWA window=512 => causal == sliding for seq<=512, no windowing needed.
import torch, traceback
mp = r'D:\MyLLM\models\spark-x26-4b\hf'
out_path = r'D:\MyLLM\models\spark-x26-4b\spark_prefill_seq512.onnx'
SEQ = 512

from transformers import AutoModelForCausalLM
print('loading fp16...', flush=True)
model = AutoModelForCausalLM.from_pretrained(mp, trust_remote_code=True, torch_dtype=torch.float16)
model.eval()
model.config.use_cache = False
print('loaded', flush=True)

class Prefill(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, ids):
        return self.m(input_ids=ids).logits

wrapper = Prefill(model.half()).eval()
ids = torch.randint(10, 100000, (1, SEQ), dtype=torch.int64)
print('exporting...', flush=True)
try:
    torch.onnx.export(
        wrapper, (ids,), out_path,
        input_names=['input_ids'], output_names=['logits'],
        opset_version=17, do_constant_folding=True, dynamo=False)
    print('EXPORT_OK', out_path, flush=True)
except Exception:
    traceback.print_exc()
    print('EXPORT_FAIL_DYNAMO_LEGACY', flush=True)
    raise SystemExit(1)
