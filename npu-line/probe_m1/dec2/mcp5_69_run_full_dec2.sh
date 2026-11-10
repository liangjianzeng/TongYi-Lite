#!/bin/bash
# [npu-line] Full-chain decode: push 42 dec2 ctxs (+norm/head), 3 resident processes split by
# HTP per-process pool (~2.3GB each), cross-process file-gate barrier, then judge logits vs HF.
# Envs: DEV (<redacted-serial>), STEPS (4), SEG_A/B/C lists optional.
# Run from Git Bash: bash mcp5_69_run_full_dec2.sh
set -e
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
D=/data/local/tmp/npu_m1
STEPS=${STEPS:-4}
PORT=8123
S=/e/MyLLM_exp/serve_dec
W=E:/wsl_stage   # adb.exe wants a Windows path, not the MSYS /e/ form

# --- precheck deliverables -------------------------------------------------
for k in $(seq 0 41); do [ -f "$S/dec2_l${k}_ctx.bin" ] || { echo MISSING_dec2_l${k}; exit 1; }; done
[ -f "$S/dec_l998norm_ctx.bin" ] && [ -f "$S/dec_l999head_ctx.bin" ] || { echo MISSING_norm_head; exit 1; }

# --- push runtime + small IO via adb ---------------------------------------
$ADB -s $DEV push E:/MyLLM_exp/_repro/rb/chain_run5 $D/bin/ >/dev/null
for f in d2e_hs0.raw d2_cos_table.raw d2_sin_table.raw d2e_ref_logits.npy; do
  [ -f "$W/$f" ] && $ADB -s $DEV push $W/$f $D/ >/dev/null
done
for t in $(seq 0 $((STEPS-1))); do   # per-step teacher-forcing feeds (realistic protocol run)
  [ -f "$W/d2e_hs_t$t.raw" ] && $ADB -s $DEV push $W/d2e_hs_t$t.raw $D/ >/dev/null
done
for k in $(seq 0 41); do
  $ADB -s $DEV push $W/d2e_kc${k}.raw $D/ >/dev/null
  $ADB -s $DEV push $W/d2e_vc${k}.raw $D/ >/dev/null
done
$ADB -s $DEV shell "cp -f $D/d2e_hs0.raw $D/d2e_hs.raw; mkdir -p $D/gate; echo 0 > $D/gate/counter; rm -f $D/cr5_*.log $D/d2e_logits.raw; chmod +x $D/bin/chain_run5"

# --- bulk ctx transfer: host http server + device curl (adbd-safe) ----------
$ADB -s $DEV reverse tcp:$PORT tcp:$PORT >/dev/null
PYW=${PYW:-/c/Users/jianz/AppData/Local/Programs/Python/Python310/python.exe}
cd "$S" && "$PYW" -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
# 740 OLED burn-in guard: never leave stayon/screen up when the run ends (see memory 740-no-stayon-burnin)
trap 'kill $SRV 2>/dev/null; '"$ADB"' -s '"$DEV"' reverse --remove-all 2>/dev/null; '"$ADB"' -s '"$DEV"' shell "svc power stayon false; input keyevent 223" 2>/dev/null' EXIT
FILES=$(for k in $(seq 0 41); do printf 'dec2_l%s_ctx.bin ' $k; done)'dec_l998norm_ctx.bin dec_l999head_ctx.bin'
# fresh download to .part then atomic rename; skip already-delivered big files (FORCE=1 refetches)
$ADB -s $DEV shell "cd $D && for f in $FILES; do
  if [ -z \"\$FORCE\" ] && [ -s \$f ] && [ \$(stat -c %s \$f) -gt 1000000 ]; then continue; fi
  curl -fsS -o \$f.part http://localhost:$PORT/\$f && mv \$f.part \$f || { echo CURL_FAIL \$f; exit 1; }
done; echo PUSHED_ALL"

# --- manifests: A=0..13 B=14..27 C=28..41+norm+head -------------------------
mklayer() { # $1=k
  printf '%s\n' "$D/dec2_l$1_ctx.bin dec2_l$1 5 \
hs 1 f2 1,2048,1 $D/d2e_hs.raw \
kcache 2 f2 1,512,128,2 $D/d2e_kc$1.raw \
vcache 3 f2 1,512,128,2 $D/d2e_vc$1.raw \
cos 4 f2 1,128,1 $D/d2_cos_table.raw@256 \
sin 5 f2 1,128,1 $D/d2_sin_table.raw@256 3 \
knew:roll=kcache@512 121 f2 1,1,128,2 - \
vnew:roll=vcache@512 123 f2 1,1,128,2 - \
h 119 f2 1,1,2048 $D/d2e_hs.raw"
}
: > /e/MyLLM_exp/manifest_dec2_A; for k in $(seq 0 13);  do mklayer $k >> /e/MyLLM_exp/manifest_dec2_A; done
: > /e/MyLLM_exp/manifest_dec2_B; for k in $(seq 14 27); do mklayer $k >> /e/MyLLM_exp/manifest_dec2_B; done
: > /e/MyLLM_exp/manifest_dec2_C; for k in $(seq 28 41); do mklayer $k >> /e/MyLLM_exp/manifest_dec2_C; done
printf '%s\n' "$D/dec_l998norm_ctx.bin dec_l998norm 1 hs 1 f2 1,2048,1 $D/d2e_hs.raw 1 h 7 f2 1,1,2048 $D/d2e_hn.raw" >> /e/MyLLM_exp/manifest_dec2_C
printf '%s\n' "$D/dec_l999head_ctx.bin dec_l999head 1 hs 1 f2 1,2048,1 $D/d2e_hn.raw 1 logits 8 f2 1,130560,1 $D/d2e_logits.raw" >> /e/MyLLM_exp/manifest_dec2_C
for m in A B C; do $ADB -s $DEV push E:/MyLLM_exp/manifest_dec2_$m $D/ >/dev/null; done

# --- launch 3 gated resident processes ---------------------------------------
# NB: must be a device-side script — inline `cd && j0 & j1 & j2` binds cd/export to j0 only,
# so siblings j1/j2 lose cwd/env and die (logs land in $HOME, invisible here).
printf '%s\n' \
"cd $D || exit 1" \
"export LD_LIBRARY_PATH=$D/lib ADSP_LIBRARY_PATH=$D/lib" \
"CHAIN_KEEP=1 CR5_GATE=$D/gate CR5_ID=0 CR5_GATE_N=3 CR5_RESEED_DIR=$D CR5_RESEED_DST=$D/d2e_hs.raw nohup ./bin/chain_run5 manifest_dec2_A $STEPS > cr5_0.log 2>&1 &" \
"CHAIN_KEEP=1 CR5_GATE=$D/gate CR5_ID=1 CR5_GATE_N=3 CR5_RESEED_DIR=$D CR5_RESEED_DST=$D/d2e_hs.raw nohup ./bin/chain_run5 manifest_dec2_B $STEPS > cr5_1.log 2>&1 &" \
"CHAIN_KEEP=1 CR5_GATE=$D/gate CR5_ID=2 CR5_GATE_N=3 CR5_RESEED_DIR=$D CR5_RESEED_DST=$D/d2e_hs.raw nohup ./bin/chain_run5 manifest_dec2_C $STEPS > cr5_2.log 2>&1 &" \
"echo LAUNCHED $STEPS" > /e/MyLLM_exp/launch3.sh
$ADB -s $DEV shell "pkill -f chain_run5; sleep 1; rm -f \$HOME/cr5_*.log; echo 0 > $D/gate/counter; rm -f $D/cr5_*.log" 2>/dev/null || true
$ADB -s $DEV push E:/MyLLM_exp/launch3.sh $D/ >/dev/null
$ADB -s $DEV shell "sh $D/launch3.sh $STEPS"
# --- wait for the tail process -------------------------------------------------
for i in $(seq 1 240); do
  # NOTE: match only fatal QNN fails — read_file's tolerant "CR5_FAIL open" prints on purpose here
  if $ADB -s $DEV shell "grep -qaE 'CR5_DONE|CR5_FAIL g_qnn' $D/cr5_2.log 2>/dev/null"; then break; fi
  sleep 2
done
$ADB -s $DEV shell "grep -ahE 'CR5' $D/cr5_0.log $D/cr5_1.log $D/cr5_2.log | tail -30"
$ADB -s $DEV pull $D/d2e_logits.raw $W/d2e_dev_logits.raw >/dev/null
wsl -d Ubuntu-22.04 -- python3 - <<'PY'
import numpy as np
dev = np.fromfile('/mnt/e/wsl_stage/d2e_dev_logits.raw', dtype='<f2').astype(np.float32).ravel()
ref = np.load('/mnt/e/wsl_stage/d2e_ref_logits.npy').ravel()
assert dev.size == ref.size, (dev.size, ref.size)
cos = dev @ ref / (np.linalg.norm(dev) * np.linalg.norm(ref) + 1e-12)
tk = 8
mt = len(set(np.argsort(-dev)[:tk]) & set(np.argsort(-ref)[:tk]))
print(f"E2E_JUDGE logits cos={cos:.4f} absmax {np.abs(dev).max():.2f}/{np.abs(ref).max():.2f} top{tk}_match={mt}/{tk} argmax dev/ref={dev.argmax()}/{ref.argmax()}")
PY
echo RUN69_DONE
