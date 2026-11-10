#!/bin/bash
# [npu-line] Device check: pre2 l0 chunked-prefill KV output, 4 chunks single process.
# Pushes runner/ctx/IO, runs chain_run5 steps=4 (host rolls kcache/vcache, ROLL_SAVE final),
# pulls new-row dumps + final caches for mcp5_75_pre2_judge.py. Screen-burn red line:
# NEVER svc power stayon; verify Dozing at exit (keyevent 223 if Awake).
set -e
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
export MSYS_NO_PATHCONV=1
R=/data/local/tmp/npu_m1
ST=E:/wsl_stage
push() { "$ADB" -s "$DEV" push "$1" "$R/" >/dev/null; }

# LF-safety for the manifest (a trailing \r would poison the last path token)
sed -i 's/\r//' "$(dirname "$0")/manifest_pre2_l0"

push E:/MyLLM_exp/_repro/rb/chain_run5
push E:/MyLLM_exp/serve_dec/dec2p_l0_ctx.bin
push "$ST/d2p_hs_0.raw"; push "$ST/d2p_hs_1.raw"; push "$ST/d2p_hs_2.raw"; push "$ST/d2p_hs_3.raw"
push "$ST/d2p_am_0.raw"; push "$ST/d2p_am_1.raw"; push "$ST/d2p_am_2.raw"; push "$ST/d2p_am_3.raw"
push "$ST/d2p_kc.raw"; push "$ST/d2p_vc.raw"
push "$ST/d2p_cos_table.raw"; push "$ST/d2p_sin_table.raw"
push E:/MyLLM_exp/_repro/rb/manifest_pre2_l0
"$ADB" -s "$DEV" shell "cd $R && chmod 755 chain_run5"

# device-side env exactly as launch3.sh convention (ADSP_LIBRARY_PATH etc.) — a bare
# inline run without them dies at deviceCreate 0x36b1 (graphExecute-side DSP side).
cat > "$(dirname "$0")/launch_pre2.sh" <<EOF
cd $R || exit 1
export LD_LIBRARY_PATH=$R/lib ADSP_LIBRARY_PATH=$R/lib
CR5_ROLL_SAVE=1 ./chain_run5 manifest_pre2_l0 4
EOF
"$ADB" -s "$DEV" push "$(dirname "$0")/launch_pre2.sh" "$R/launch_pre2.sh" >/dev/null
"$ADB" -s "$DEV" shell "cd $R && chmod 755 launch_pre2.sh && ./launch_pre2.sh"

mkdir -p /e/wsl_stage/dev
for f in d2p_knew_0 d2p_knew_1 d2p_knew_2 d2p_knew_3 d2p_vnew_0 d2p_vnew_1 d2p_vnew_2 d2p_vnew_3 d2p_kc d2p_vc; do
  "$ADB" -s "$DEV" pull "$R/$f.raw" E:/wsl_stage/dev/$f.raw >/dev/null
done

W=$("$ADB" -s "$DEV" shell dumpsys power | grep -m1 mWakefulness | tr -d '\r')
echo "WAKE: $W"
case "$W" in *Awake*) "$ADB" -s "$DEV" shell input keyevent 223; echo "SCREEN turned off (223)";; esac
echo "RUN76_DONE"
