#!/bin/bash
# [npu-line] G3: full validator-error context for W8 ablation builds (avoid $-var in MSYS).
for T in w8abq_l0 w8abk_l0 w8abg_l0; do
  echo "======${T}======"
  grep -a -B14 '0xc26' "/home/liang/w4sim/ctx_${T}/ctxgen.log" | head -46
done
