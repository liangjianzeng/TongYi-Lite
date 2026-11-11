#!/bin/bash
# [npu-line] G3: batch-build all 42 W8 decode layers (w8nc640_l{K}) with the hardened
# stack (dict-schema enc.json per layer + FC fold + FIXUP5). PARA=2 default.
set -u
FROM=${1:-0}; TO=${2:-41}
RBD=/mnt/e/MyLLM_exp/_repro/rb
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
seq "$FROM" "$TO" | xargs -P "${PARA:-2}" -I{} bash -c \
  "L=/home/liang/models/mcp5_dec2_640/mcp5_nc640_l{}.onnx; \
   python3 -u $RBD/mcp5_93_gen_enc.py \$L /home/liang/l{}_enc.json && \
   ONNXOVERRIDE=\$L ENCOVR=/home/liang/l{}_enc.json bash $RBD/mcp5_93_build_w8.sh w8nc640_l{} \
     > /home/liang/w8build_l{}.log 2>&1 && echo OK_{} || echo FAIL_{}"
