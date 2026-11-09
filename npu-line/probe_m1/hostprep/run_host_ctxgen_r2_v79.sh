#!/bin/bash
# [C33] HOST-side HTP prepare of spark_v4w32r2 for 830 (SM8750/V79).
# Produces /mnt/e/MyLLM_exp/r2ctx_v79/spark_r2_v79_ctx.bin for on-device net-run.
set -e
SDK=/mnt/d/MyLLM/qairt/2.44.0.260225
OUT=/mnt/e/MyLLM_exp/r2ctx_v79
mkdir -p "$OUT"
export LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang
export QNN_MODEL_DATA_DIR=/mnt/e/MyLLM_exp/r2raws
cd "$OUT"
time "$SDK/bin/x86_64-linux-clang/qnn-context-binary-generator" \
  --model /mnt/e/MyLLM_exp/x86_out/libspark_v4w32r2.so \
  --backend "$SDK/lib/x86_64-linux-clang/libQnnHtp.so" \
  --config_file /mnt/e/MyLLM_exp/_repro/host_cfg_r3.json \
  --binary_file spark_r2_v79_ctx \
  --output_dir "$OUT" 2>&1 | tail -40
ls -la "$OUT"
echo HOST_CTXGEN_V79_DONE
