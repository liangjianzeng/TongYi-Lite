#!/bin/bash
# [npu-line] Export all 42 NC=640 decode graphs and stage nc640 copies for build.
set -e
cd /mnt/e/MyLLM_exp/_repro/rb
DEC_NC=640 DEC_S=1 DEC_NTAB=16 PYTHONIOENCODING=utf-8 python3 mcp5_63_export_dec2.py all > /home/liang/nc640_export.log 2>&1
grep -c 'DEC2_EXPORT_DONE' /home/liang/nc640_export.log
grep -c 'EXPORT_OK' /home/liang/nc640_export.log
D=/home/liang/models/mcp5_dec2_640
for k in $(seq 0 41); do
  cp "$D/mcp5_dec2_l$k.onnx" "$D/mcp5_nc640_l$k.onnx"
  cp "$D/mcp5_dec2_l$k.onnx.data" "$D/mcp5_nc640_l$k.onnx.data"
done
ls "$D" | grep -c 'nc640_l.*\.onnx$'
echo NC640_EXPORT_STAGED
