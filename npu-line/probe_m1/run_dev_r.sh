#!/bin/bash
# [C32] Winning-recipe device flow. $1 = adb serial. push libspark_v4w32r2.so -> ctx bin
# -> net-run warmup x1 + timed x10 (profiling basic, burst perf) ; pull profiling logs.
export MSYS_NO_PATHCONV=1
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
S=$1
D=/data/local/tmp/npu_m1
echo "===== [$S] push libspark_v4w32r2.so ====="
time "$ADB" -s $S push E:/MyLLM_exp/v4w32r_out/aarch64-android/libspark_v4w32r2.so $D/libspark_v4w32r2.so
"$ADB" -s $S shell "ls -la $D/libspark_v4w32r2.so"
echo "===== [$S] ctx binary generation (on-device HTP prepare) ====="
time "$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && ./bin/qnn-context-binary-generator --model $D/libspark_v4w32r2.so --backend $D/lib/libQnnHtp.so --binary_file spark_r_ctx --output_dir $D 2>&1 | tail -25; ls -la $D/spark_r_ctx.bin 2>/dev/null"
echo "===== [$S] net-run warmup x1 ====="
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && ./bin/qnn-net-run --backend $D/lib/libQnnHtp.so --retrieve_context $D/spark_r_ctx.bin --input_list $D/input_list.txt --output_dir $D/out_rw --perf_profile burst 2>&1 | grep -iE 'error|fail|Executing|Finished' | head -8"
echo "===== [$S] net-run TIMED x10 (profiling basic, burst) ====="
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && ./bin/qnn-net-run --backend $D/lib/libQnnHtp.so --retrieve_context $D/spark_r_ctx.bin --input_list $D/input_list.txt --output_dir $D/out_rt --perf_profile burst --profiling_level basic --num_inferences 10 2>&1 | grep -iE 'error|fail|Executing|Finished' | head -8"
mkdir -p "E:/MyLLM_exp/_perf/$S"
"$ADB" -s $S pull $D/out_rt/qnn-profiling-data_0.log "E:/MyLLM_exp/_perf/$S/spark_r_prof.log" 2>/dev/null
echo "===== RUN_DEV_R_DONE $S ====="
