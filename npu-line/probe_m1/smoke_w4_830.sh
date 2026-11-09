#!/system/bin/sh
# Smoke run: w4a16 model .so on 830 (one-shot timing, not formal gate).
# Prereq: user transferred libspark_v4_w4_qnn.so to /data/local/tmp/npu_m1/lib/
D=/data/local/tmp/npu_m1
export LD_LIBRARY_PATH=$D/lib:$LD_LIBRARY_PATH
export ADSP_LIBRARY_PATH="$D/lib;/system/lib/rfsa/adsp;/system/vendor/lib/rfsa/adsp;/dsp"
cd $D
echo ===FILES===
ls -la lib/libspark_v4_w4_qnn.so bin/qnn-net-run input_list.txt 2>&1
echo ===INPUT===
ls -la input_ids.raw 2>&1
echo ===RUN===
echo "input_ids.raw" > input_list_w4.txt
START=$(date +%s.%N)
./bin/qnn-net-run --model lib/libspark_v4_w4_qnn.so \
  --backend lib/libQnnHtp.so \
  --input_list input_list_w4.txt \
  --output_dir out_w4 2>&1 | tail -30
RC=$?
END=$(date +%s.%N)
echo SMOKE_RC=$RC
echo "WALL=$(echo "$END $START" | awk '{printf "%.2f", $1-$2}')s (incl. graph build)"
echo ===OUT===
ls -la out_w4/ 2>/dev/null | head -5
echo ===END===
