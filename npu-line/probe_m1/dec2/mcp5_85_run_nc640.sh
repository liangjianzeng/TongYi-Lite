#!/bin/bash
# [npu-line] NC=640 decode chain: real prefill-terminal KV (640-row padded) -> 8 greedy
# steps, teacher-forced. Avoids the HTP S=1 K=513 attention-kernel collapse (pitfall 52).
# Red line: no stayon; verify Dozing at exit.
set -e
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
export MSYS_NO_PATHCONV=1
R=/data/local/tmp/npu_m1
ST=E:/wsl_stage
sh() { "$ADB" -s "$DEV" shell "$@"; }
push() { "$ADB" -s "$DEV" push "$1" "$R/" >/dev/null; }

# 0) push 42 nc640 ctxs + padded caches + rope tables + per-step amasks + feeds + manifests
# (SKIP_BIG=1 reuses ctxs/caches already staged on device from a previous run)
if [ -z "${SKIP_BIG:-}" ]; then
  for i in $(seq 0 41); do push E:/MyLLM_exp/serve_dec/nc640_l${i}_ctx.bin; done
  for i in $(seq 0 41); do push "$ST/d2e640_kc${i}.raw"; push "$ST/d2e640_vc${i}.raw"; done
fi
push "$ST/d2_cos_table.raw"; push "$ST/d2_sin_table.raw"
for t in 0 1 2 3 4 5 6 7; do push "$ST/g_am640_t${t}.raw"; done
push "$ST/d2e_hs0.raw"
for t in 1 2 3 4 5 6 7; do push "$ST/d2e_hs_t${t}.raw"; done
for m in A B C; do push E:/MyLLM_exp/manifest_nc640_$m; done
push E:/MyLLM_exp/_repro/rb/chain_run5
sh "chmod 755 $R/chain_run5"

# 1) launch 3 gated processes, steps=8
cat > "$(dirname "$0")/launch_nc640.sh" <<EOF
cd $R || exit 1
export LD_LIBRARY_PATH=$R/lib ADSP_LIBRARY_PATH=$R/lib
pkill -f chain_run5 2>/dev/null || true; sleep 1
cp -f d2e_hs0.raw d2e_hs.raw
# canonicalize the t=0 reseed feed from hs0 (stale d2e_hs_t0.raw residue poisons step 0)
cp -f d2e_hs0.raw d2e_hs_t0.raw
rm -rf gate; mkdir -p gate; echo 0 > gate/counter
rm -f d2e_logits_t*.raw d2e_hn.raw cr5_*.log
CHAIN_KEEP=1 CR5_RESEED_DIR=$R CR5_RESEED_DST=$R/d2e_hs.raw CR5_GATE=$R/gate CR5_ID=0 CR5_GATE_N=3 nohup ./chain_run5 manifest_nc640_A 8 > cr5_0.log 2>&1 &
CHAIN_KEEP=1 CR5_RESEED_DIR=$R CR5_RESEED_DST=$R/d2e_hs.raw CR5_GATE=$R/gate CR5_ID=1 CR5_GATE_N=3 nohup ./chain_run5 manifest_nc640_B 8 > cr5_1.log 2>&1 &
CHAIN_KEEP=1 CR5_RESEED_DIR=$R CR5_RESEED_DST=$R/d2e_hs.raw CR5_GATE=$R/gate CR5_ID=2 CR5_GATE_N=3 nohup ./chain_run5 manifest_nc640_C 8 > cr5_2.log 2>&1 &
echo LAUNCHED_NC640
EOF
"$ADB" -s "$DEV" push "$(dirname "$0")/launch_nc640.sh" "$R/launch_nc640.sh" >/dev/null
sh "chmod 755 $R/launch_nc640.sh"
sh "cd $R && ./launch_nc640.sh"
for k in 0 1 2; do
  for t in $(seq 1 120); do
    if sh "grep -qa 'CR5_DONE' $R/cr5_$k.log 2>/dev/null"; then break; fi
    if ! sh "pgrep -f chain_run5 >/dev/null 2>&1"; then echo "chain_run5 gone (crash?)"; break; fi
    sleep 5
  done
  echo "---- cr5_$k.log ----"
  sh "grep -aE 'CR5_DONE|CR5_FAIL g_qnn|CR5_FAIL roll|CR5_FAIL gate|CR5_STEP' $R/cr5_$k.log | tail -10"
done

# 2) pull per-step logits
mkdir -p /e/wsl_stage/dev
for t in 0 1 2 3 4 5 6 7; do
  "$ADB" -s "$DEV" pull "$R/d2e_logits_t${t}.raw" E:/wsl_stage/dev/d2e_logits_t${t}.raw >/dev/null
done

W=$(sh "dumpsys power | grep -m1 mWakefulness" | tr -d '\r')
echo "WAKE: $W"
case "$W" in *Awake*) sh "input keyevent 223"; echo "SCREEN turned off (223)";; esac
echo "RUN85_DONE"
