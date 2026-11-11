#!/bin/bash
# [npu-line] G3: head W8 via dict-schema param_encodings — regenerate enc.json + rebuild.
set -e
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
RBD=/mnt/e/MyLLM_exp/_repro/rb
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
HEAD=/home/liang/models/mcp5_dec/mcp5_dec_l999head.onnx
python3 -u $RBD/mcp5_93_gen_enc.py $HEAD /home/liang/head_enc.json
export ONNXOVERRIDE=$HEAD ENCOVR=/home/liang/head_enc.json
bash $RBD/mcp5_93_build_w8.sh w8dec_l999head
