#!/bin/bash
# [npu-line] Full 4-chunk chunked-prefill e2e on 740: 42 pre2 layers, 3 gate-locked
# resident processes (A l0-13 / B l14-27 / C l28-41), per-layer host-rolled KV caches.
# Judge = device l41 last-token row -> host-side norm+head -> logits vs HF ref (d2q_ref_logits.npy).
# Red line: NEVER stayon; verify Dozing at exit.
set -e
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
export MSYS_NO_PATHCONV=1
R=/data/local/tmp/npu_m1
ST=E:/wsl_stage
sh() { "$ADB" -s "$DEV" shell "$@"; }

# 0) push runner, 42 ctxs, IO (emb/mask/rope/zero-cache), manifests
push() { "$ADB" -s "$DEV" push "$1" "$R/" >/dev/null; }
push E:/MyLLM_exp/_repro/rb/chain_run5
for i in $(seq 0 41); do push E:/MyLLM_exp/serve_dec/dec2p_l${i}_ctx.bin; done
for f in d2q_emb_0 d2q_emb_1 d2q_emb_2 d2q_emb_3 d2q_am_0 d2q_am_1 d2q_am_2 d2q_am_3 \
         d2q_cos_table d2q_sin_table d2q_kc0 d2q_vc0; do push "$ST/$f.raw"; done
for g in A B C; do push E:/MyLLM_exp/manifest_pre2_$g; done
sh "chmod 755 $R/chain_run5"

# 1) seed per-layer cache copies + clean stale relays, then launch 3 gated processes
cat > "$(dirname "$0")/launch_pre2_full.sh" <<EOF
cd $R || exit 1
export LD_LIBRARY_PATH=$R/lib ADSP_LIBRARY_PATH=$R/lib
pkill -f chain_run5 2>/dev/null || true; sleep 1
rm -f d2q_h_l*_* d2q_knew_* d2q_vnew_* d2q_kc_*.raw d2q_vc_*.raw
# THE gate is a DIRECTORY holding the counter file (chain_run5: <dir>/counter) —
# rm -f on a stale dir silently fails and the leftover counter lets B/C bypass
# their wait and crash on missing relays (outage 2026-11-10). Rebuild + zero it.
rm -rf gate; mkdir -p gate; echo 0 > gate/counter
for i in \$(seq 0 41); do cp d2q_kc0.raw d2q_kc_\$i.raw; cp d2q_vc0.raw d2q_vc_\$i.raw; done
CHAIN_KEEP=1 CR5_ROLL_SAVE=1 CR5_GATE=$R/gate CR5_ID=0 CR5_GATE_N=3 nohup ./chain_run5 manifest_pre2_A 4 > p0.log 2>&1 &
CHAIN_KEEP=1 CR5_ROLL_SAVE=1 CR5_GATE=$R/gate CR5_ID=1 CR5_GATE_N=3 nohup ./chain_run5 manifest_pre2_B 4 > p1.log 2>&1 &
CHAIN_KEEP=1 CR5_ROLL_SAVE=1 CR5_GATE=$R/gate CR5_ID=2 CR5_GATE_N=3 nohup ./chain_run5 manifest_pre2_C 4 > p2.log 2>&1 &
echo LAUNCHED_PRE2
EOF
"$ADB" -s "$DEV" push "$(dirname "$0")/launch_pre2_full.sh" "$R/launch_pre2_full.sh" >/dev/null
sh "chmod 755 $R/launch_pre2_full.sh"

# 2) launch + wait for all three CR5_DONE. NB: preload emits BENIGN 'CR5_FAIL open'
# lines (tolerant zero-fill, pitfall 42) — never grep for generic CR5_FAIL here; wait
# on CR5_DONE only, plus a process-liveness bail-out.
sh "cd $R && ./launch_pre2_full.sh"
for k in 0 1 2; do
  for t in $(seq 1 180); do
    if sh "grep -qa 'CR5_DONE' $R/p$k.log 2>/dev/null"; then break; fi
    if ! sh "pgrep -f chain_run5 >/dev/null 2>&1"; then echo "chain_run5 gone (crash?)"; break; fi
    sleep 5
  done
  echo "---- p$k.log ----"
  sh "grep -aE 'CR5_DONE|CR5_FAIL g_qnn|CR5_FAIL roll|CR5_FAIL gate|CR5_STEP' $R/p$k.log | tail -6"
done

# 3) pull the final-layer last-chunk hidden state
mkdir -p /e/wsl_stage/dev
"$ADB" -s "$DEV" pull "$R/d2q_h_l41_3.raw" E:/wsl_stage/dev/d2q_h_l41_3.raw >/dev/null
"$ADB" -s "$DEV" pull "$R/d2q_kc_41.raw" E:/wsl_stage/dev/d2q_kc_41.raw >/dev/null 2>&1 || true
"$ADB" -s "$DEV" pull "$R/d2q_vc_41.raw" E:/wsl_stage/dev/d2q_vc_41.raw >/dev/null 2>&1 || true

sh "pkill -f chain_run5" 2>/dev/null || true
W=$(sh "dumpsys power | grep -m1 mWakefulness" | tr -d '\r')
echo "WAKE: $W"
case "$W" in *Awake*) sh "input keyevent 223"; echo "SCREEN turned off (223)";; esac
echo "RUN79_DONE"
