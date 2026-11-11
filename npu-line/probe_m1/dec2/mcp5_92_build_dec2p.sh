#!/bin/bash
# [npu-line] G2 final: rebuild all 42 prefill ctxs as TAG=dec2p_l{k} from the IN-PLACE
# tiled staged onnx (graph name matches manifest_pre2_*; ctx graphRetrieve 0x1773 lesson:
# qnn-onnx-converter names the graph after --output_path TAG, not the onnx graph name).
set -u
cd "$(dirname "$0")"
FROM=${1:-0}; TO=${2:-41}
seq "$FROM" "$TO" | xargs -P "${PARA:-2}" -I{} bash -c \
  "DEC_NC=512_s128 bash mcp5_65_build_dec2.sh dec2p_l{} > /home/liang/g2p_l{}.log 2>&1 && echo OK_{} || echo FAIL_{}"
echo BUILD_DEC2P_DONE
