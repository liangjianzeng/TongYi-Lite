#!/bin/bash
# [npu-line] dec2 l0 NC=128 control: same as mcp5_66 but cache [1,128,128,2].
# Measures attention-op share vs weight-stream floor (exec @NC512 was 11.0-12.6ms).
# Run from Git Bash: bash mcp5_66b_run_dec2_l0_n128.sh
set -e
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
D=/data/local/tmp/npu_m1
$ADB -s $DEV push E:/MyLLM_exp/_repro/rb/chain_run5 $D/bin/ >/dev/null
$ADB -s $DEV push E:/MyLLM_exp/serve_dec/dec2_l0n128_ctx.bin $D/ >/dev/null
for f in d2_hs0.raw d2_kc.raw d2_vc.raw d2_cos_table.raw d2_sin_table.raw; do
  $ADB -s $DEV push E:/wsl_stage/$f $D/ >/dev/null
done
$ADB -s $DEV shell "cp -f $D/d2_hs0.raw $D/d2_hs.raw; chmod +x $D/bin/chain_run5"
# NB: converter names the graph after the ONNX file basename (TAG), not onnx graph.name
printf '%s\n' "$D/dec2_l0n128_ctx.bin dec2_l0n128 5 hs 1 f2 1,2048,1 $D/d2_hs.raw kcache 2 f2 1,128,128,2 $D/d2_kc.raw vcache 3 f2 1,128,128,2 $D/d2_vc.raw cos 4 f2 1,128,1 $D/d2_cos_table.raw@256 sin 5 f2 1,128,1 $D/d2_sin_table.raw@256 3 knew:roll=kcache@512 121 f2 1,1,128,2 $D/d2_knew.raw vnew:roll=vcache@512 123 f2 1,1,128,2 $D/d2_vnew.raw h 119 f2 1,1,2048 $D/d2_hs.raw" > /e/MyLLM_exp/manifest_dec2_l0_n128
$ADB -s $DEV push E:/MyLLM_exp/manifest_dec2_l0_n128 $D/ >/dev/null
$ADB -s $DEV shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH=$D/lib && CHAIN_KEEP=1 ./bin/chain_run5 manifest_dec2_l0_n128 3 2>&1 | grep -aE 'CR5'"
$ADB -s $DEV pull $D/d2_hs.raw E:/wsl_stage/d2_dev_h_final.raw >/dev/null
wsl -d Ubuntu-22.04 -- python3 - <<'PY'
import numpy as np
dev = np.fromfile('/mnt/e/wsl_stage/d2_dev_h_final.raw', dtype='<f2').astype(np.float32)
ref = np.load('/mnt/e/wsl_stage/d2_ref_h2.npy').astype(np.float32).ravel()
cos = dev @ ref / (np.linalg.norm(dev) * np.linalg.norm(ref) + 1e-12)
print(f"JUDGE NC128 dev_h(step2) vs ORT-chain ref cos={cos:.4f} absmax {np.abs(dev).max():.3f}/{np.abs(ref).max():.3f}")
PY
echo RUN66B_DONE
