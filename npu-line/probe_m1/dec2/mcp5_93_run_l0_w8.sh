#!/bin/bash
# [npu-line] G3: one real GQA decode layer (nc640 l0) through the W8 stack — tests
# whether the "batch 8 != 1" quantized-FC validator failure was the IO-orientation
# artifact that FIXUP5 fixed.
set -e
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
RBD=/mnt/e/MyLLM_exp/_repro/rb
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
L0=/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx
python3 -u $RBD/mcp5_93_gen_enc.py $L0 /home/liang/l0_enc.json
export ONNXOVERRIDE=$L0 ENCOVR=/home/liang/l0_enc.json
bash $RBD/mcp5_93_build_w8.sh w8nc640_l0
