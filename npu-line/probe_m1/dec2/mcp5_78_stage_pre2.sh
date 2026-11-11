#!/bin/bash
# [npu-line] Summarize pre2 all-export vs-HF, then stage dec2p_l{k}.onnx copies for build.
D=/home/liang/models/mcp5_dec2_512_s128
echo "== suspect lines (any of h/k/v < 0.999) =="
grep -aE 'vs-HF' /home/liang/pre2_export_all.log | while read -r l; do
  hv=$(echo "$l" | sed -n 's/.*h=\([0-9.]*\).*/\1/p')
  kv=$(echo "$l" | sed -n 's/.*k=\([0-9.-]*\).*/\1/p')
  vv=$(echo "$l" | sed -n 's/.*v=\([0-9.-]*\).*/\1/p')
  bad=$(awk -v h="$hv" -v k="$kv" -v v="$vv" 'BEGIN{print (h<0.999||k<0.999||v<0.999)?1:0}')
  [ "$bad" = 1 ] && echo "$l"
done
echo "== total judged =="
grep -acE 'vs-HF' /home/liang/pre2_export_all.log
echo "== staging dec2p copies =="
for k in $(seq 0 41); do
  cp "$D/mcp5_dec2_l$k.onnx" "$D/mcp5_dec2p_l$k.onnx" || echo "MISS_$k"
done
# G2 (2026-11-11): Tile-inject the amask broadcast-add on the staged copies — HTP pays
# ~13ms/layer/chunk on the [2,8,128,640]+[1,1,128,640] broadcast path; an explicit
# Tile(amask,[2,8,1,1]) before the Add recovers ~36% exec, BIT-EXACT device outputs
# (mcp5_92 A/B: baseline 120.7 -> tile 77.2 ms / 4 steps, single l0). dynamo folds a
# PyTorch-side expand back, so the injection must be post-export (see mcp5_92 script).
cd /mnt/e/MyLLM_exp/_repro/rb && python3 mcp5_92_g2_variants.py tileall
cd - >/dev/null
ls "$D" | grep -c 'dec2p_l.*\.onnx'
