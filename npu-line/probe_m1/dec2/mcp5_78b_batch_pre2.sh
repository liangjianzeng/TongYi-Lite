#!/bin/bash
# [npu-line] Batch-build masked pre2 ctxs (dec2p_l{K}) layers $1..$2. Env: PARA (default 2).
# Mirrors mcp5_67 but with the dec2p tag (DEC_NC=512_s128 directory convention).
set -u
FROM=${1:-0}; TO=${2:-41}
cd "$(dirname "$0")"
seq "$FROM" "$TO" | xargs -P "${PARA:-2}" -I{} bash -c \
  "DEC_NC=512_s128 bash mcp5_65_build_dec2.sh dec2p_l{} > /home/liang/pre2_build_l{}.log 2>&1 && echo OK_{} || echo FAIL_{}"
