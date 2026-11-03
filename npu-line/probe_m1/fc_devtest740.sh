#!/bin/bash
# [C31] Device compose probe on 740 (98fc9410): push libfc_*.so + run ctx-gen. $1 = variant
export MSYS_NO_PATHCONV=1
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
S=98fc9410
D=/data/local/tmp/npu_m1
V=$1
"$ADB" -s $S push "E:/MyLLM_exp/_repro/${V}_and/aarch64-android/lib${V}.so" $D/lib${V}.so >/dev/null 2>&1 && echo PUSHED
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && ./bin/qnn-context-binary-generator --model $D/lib${V}.so --backend $D/lib/libQnnHtp.so --binary_file ${V}_ctx --output_dir $D 2>&1 | tail -25; ls -la $D/${V}_ctx.bin 2>/dev/null"
echo DEVTEST_DONE
