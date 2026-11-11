#!/bin/bash
# [npu-line] G3: batch-build all 42 native-converter W8 decode layers (w8nat_l{K}).
# Native CLI + per-layer enc -> cpp/bin -> model.so -> ctxgen (the GREEN flow proven by
# w8nat_l0: knew cos=0.999988 / vnew 0.999640, exec 13.4ms, 46M/layer). Env PARA=2.
set -u
FROM=${1:-0}; TO=${2:-41}
cd "$(dirname "$0")"
seq "$FROM" "$TO" | xargs -P "${PARA:-2}" -I{} bash -c \
  "ONNXOVERRIDE=/home/liang/models/mcp5_dec2_640/mcp5_nc640_l{}.onnx \
   ENCOVR=/home/liang/l{}_enc.json \
   bash mcp5_93_build_natw8.sh w8nat_l{} > /home/liang/natw8_l{}.log 2>&1 \
   && echo OK_{} || echo FAIL_{}"
echo BATCH_NATW8_DONE
