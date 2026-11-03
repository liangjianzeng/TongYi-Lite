#!/bin/bash
# [C33] Device flow for HOST-prepared ctx: push spark_r2_ctx.bin -> net-run warmup x1
# + timed x10 (profiling basic, burst) ; pull profiling logs. $1 = adb serial.
export MSYS_NO_PATHCONV=1
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
S=$1
D=/data/local/tmp/npu_m1
CTX=${2:-E:/MyLLM_exp/r2ctx/spark_r2_ctx.bin}
TAG=${3:-spark_r2}
echo "===== [$S] push host-prepared ctx ====="
time "$ADB" -s $S push "$CTX" $D/${TAG}_ctx.bin
"$ADB" -s $S shell "ls -la $D/${TAG}_ctx.bin"
echo "===== [$S] net-run warmup x1 ====="
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && ./bin/qnn-net-run --backend $D/lib/libQnnHtp.so --retrieve_context $D/${TAG}_ctx.bin --input_list $D/input_list.txt --output_dir $D/out_${TAG}_w --perf_profile burst 2>&1 | grep -iE 'error|fail|Executing|Finished' | head -8"
echo "===== [$S] net-run TIMED x10 (profiling basic, burst) ====="
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && ./bin/qnn-net-run --backend $D/lib/libQnnHtp.so --retrieve_context $D/${TAG}_ctx.bin --input_list $D/input_list.txt --output_dir $D/out_${TAG}_t --perf_profile burst --profiling_level basic --num_inferences 10 2>&1 | grep -iE 'error|fail|Executing|Finished' | head -8"
mkdir -p "E:/MyLLM_exp/_perf/$S"
"$ADB" -s $S pull $D/out_${TAG}_t/qnn-profiling-data_0.log "E:/MyLLM_exp/_perf/$S/${TAG}_prof.log" 2>/dev/null
"$ADB" -s $S pull $D/out_${TAG}_t "E:/MyLLM_exp/_perf/$S/${TAG}_out" 2>/dev/null | tail -1
echo "===== RUN_DEV_CTX_DONE $S ====="
