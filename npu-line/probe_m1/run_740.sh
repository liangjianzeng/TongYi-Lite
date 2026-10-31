#!/bin/bash
# Device-side NPU execution for 740 (Adreno 740 / Hexagon V73), serial 98fc9410
ADB="D:/TongYi-Lite/.tmp_platform_tools/platform-tools/adb.exe"
S=98fc9410
D=/data/local/tmp/npu_m1

echo "===== push model lib + inputs ====="
"$ADB" -s $S push E:/MyLLM_exp/v2_out/aarch64-android/libspark_v2.so $D/
"$ADB" -s $S push D:/TongYi-Lite/_probe_m1/in/input_ids.raw $D/in_input_ids.raw
"$ADB" -s $S push D:/TongYi-Lite/_probe_m1/in/input.list $D/input.list

echo "===== context binary generation (on-device, V73) ====="
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && $D/bin/qnn-context-binary-generator --model $D/libspark_v2.so --backend $D/lib/libQnnHtp.so --binary_file spark_v2_ctx --output_dir $D 2>&1 | tail -30; ls -la $D/spark_v2_ctx.bin 2>/dev/null"

echo "===== qnn-net-run x3 (profiling basic) ====="
"$ADB" -s $S shell "cd $D && export LD_LIBRARY_PATH=$D/lib && export ADSP_LIBRARY_PATH='//$D/lib;native' && for i in 1 2 3; do $D/bin/qnn-net-run --backend $D/lib/libQnnHtp.so --retrieve_context $D/spark_v2_ctx.bin --input_list $D/input.list --output_dir $D/out --profiling_options basic 2>&1 | grep -E 'Graph|execution|Peak|error|Error|fail'; echo ---run \$i done---; done; ls -la $D/out/ | head"
echo "===== RUN740_DONE ====="
