#!/bin/bash
# [npu-line] G3 ablation: quantize ONLY $2 (comma list) of layer 0, build TAG=$1, probe.
set -e
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
RBD=/mnt/e/MyLLM_exp/_repro/rb
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
TAG=$1; ONLY=$2
L0=/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx
python3 -u $RBD/mcp5_93_gen_enc.py $L0 /home/liang/${TAG}_enc.json "$ONLY"
ONNXOVERRIDE=$L0 ENCOVR=/home/liang/${TAG}_enc.json bash $RBD/mcp5_93_build_w8.sh $TAG | tail -2
CTXTAG=$TAG python3 -u $RBD/mcp5_93_l0_devprobe.py 2>/dev/null | grep -E "DEV|cos"
