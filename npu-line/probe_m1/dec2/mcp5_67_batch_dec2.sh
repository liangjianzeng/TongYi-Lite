#!/bin/bash
# [npu-line] Batch-build dec2 ctxs for layers $1..$2 (inclusive). Env: DEC_NC (default 512), PARA (default 3).
# Per-layer log: /home/liang/dec2_build_l{K}.log ; prints OK_K / FAIL_K lines.
set -u
FROM=${1:-0}; TO=${2:-41}
NC=${DEC_NC:-512}
cd "$(dirname "$0")"
seq "$FROM" "$TO" | xargs -P "${PARA:-3}" -I{} bash -c \
  "DEC_NC=$NC bash mcp5_65_build_dec2.sh dec2_l{} > /home/liang/dec2_build_l{}.log 2>&1 && echo OK_{} || echo FAIL_{}"
