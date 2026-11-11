#!/bin/bash
# [npu-line] Batch-build NC=640 decode ctxs (nc640_l{K}). Env: PARA (default 2).
set -u
FROM=${1:-0}; TO=${2:-41}
cd "$(dirname "$0")"
seq "$FROM" "$TO" | xargs -P "${PARA:-2}" -I{} bash -c \
  "DEC_NC=640 bash mcp5_65_build_dec2.sh nc640_l{} > /home/liang/nc640_build_l{}.log 2>&1 && echo OK_{} || echo FAIL_{}"
