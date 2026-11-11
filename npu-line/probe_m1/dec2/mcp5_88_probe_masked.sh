#!/bin/bash
# [npu-line] Masked single-layer probe: nc640 l0 with REAL per-step amask (t=0 window
# [512:640]) on chain step-0 inputs. Device h vs ORT h (same bytes) decides whether the
# HTP S=1 attention kernel still collapses at K=641 once pads are actually masked.
set -e
ADB=/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
DEV=${DEV:-<redacted-serial>}
export MSYS_NO_PATHCONV=1
R=/data/local/tmp/npu_m1
ST=E:/wsl_stage
sh() { "$ADB" -s "$DEV" shell "$@"; }
push() { "$ADB" -s "$DEV" push "$1" "$R/" >/dev/null; }

push E:/MyLLM_exp/_repro/rb/manifest_nc640_probe2
push E:/MyLLM_exp/_repro/rb/launch_probe2.sh
push "$ST/d2e_hs0.raw"
push "$ST/g_am640_t0.raw"
sh "cd $R && ./launch_probe2.sh"
"$ADB" -s "$DEV" pull "$R/g_dev_h640m.raw" E:/wsl_stage/g_dev_h640m.raw >/dev/null
"$ADB" -s "$DEV" pull "$R/g_dev_knew640m.raw" E:/wsl_stage/g_dev_knew640m.raw >/dev/null
W=$(sh "dumpsys power | grep -m1 mWakefulness" | tr -d '\r')
echo "WAKE: $W"
case "$W" in *Awake*) sh "input keyevent 223"; echo "SCREEN off";; esac
echo PROBE88_DONE
