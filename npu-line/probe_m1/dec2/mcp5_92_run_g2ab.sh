#!/bin/bash
# [npu-line] G2 A/B timing: run each dec2p l0 variant 4 chunks single-process, print
# CR5_STEP exec lines. Screen-burn red line: NEVER svc power stayon; verify Dozing at
# exit (keyevent 223 if Awake). Run from Git Bash.
set -e
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
export MSYS_NO_PATHCONV=1
R=/data/local/tmp/npu_m1
ST=E:/wsl_stage
sh_dev() { "$ADB" -s "$DEV" shell "cd $R && $1"; }
push() { "$ADB" -s "$DEV" push "$1" "$R/" >/dev/null; }

"$ADB" -s "$DEV" shell "pkill -f chain_run5" 2>/dev/null || true
sleep 1

# shared feeds (77-era real-prompt prefill inputs)
for f in d2q_emb_0 d2q_emb_1 d2q_emb_2 d2q_emb_3 d2q_am_0 d2q_am_1 d2q_am_2 d2q_am_3 \
         d2q_cos_table d2q_sin_table g2_kc0 g2_vc0; do
  push "$ST/$f.raw"
done
push E:/MyLLM_exp/_repro/rb/chain_run5
"$ADB" -s "$DEV" shell "cd $R && chmod 755 chain_run5"

for TAG in dec2p_l0 dec2pt_l0 dec2pc_l0 dec2pn_l0; do
  push E:/MyLLM_exp/serve_dec/${TAG}_ctx.bin
  sed -i 's/\r//' E:/MyLLM_exp/_repro/rb/manifest_g2_${TAG}
  push E:/MyLLM_exp/_repro/rb/manifest_g2_${TAG}
  echo "=== $TAG ==="
  sh_dev "LD_LIBRARY_PATH=$R/lib ADSP_LIBRARY_PATH=$R/lib ./chain_run5 manifest_g2_${TAG} 4 2>&1 | grep -aE 'CR5_STEP|CR5_DONE|FAIL|ERROR'"
  mkdir -p /e/wsl_stage/g2dev
  for t in 0 1 2 3; do
    for o in h k v; do
      "$ADB" -s "$DEV" pull "$R/g2${o}_${TAG}_${t}.raw" E:/wsl_stage/g2dev/ >/dev/null 2>&1 || true
    done
  done
done

W=$("$ADB" -s "$DEV" shell dumpsys power | grep -m1 mWakefulness | tr -d '\r')
echo "WAKE: $W"
case "$W" in *Awake*) "$ADB" -s "$DEV" shell input keyevent 223; echo "SCREEN turned off (223)";; esac
echo "RUN92_DONE"
