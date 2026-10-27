#!/system/bin/sh
# R-078 740 B0 对账腿：35B les（=k40moe mix 同源）装载判决抓取。
# 前置：arb740 队列 DONE（设备道列 SERIAL）。禁队列中打断。
R=/data/local/tmp/mesa_clrt_1026
LOADER=$R/lib/ld-linux-aarch64.so.1
LP=$R/bin/patch78:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
X=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts/manifest.json
BIN=$(md5sum $R/bin/patch78/libggml-opencl.so.0.27.0 2>/dev/null | cut -c1-8)
[ "$BIN" = "7f6114b2" ] || [ "$BIN" = "2695a8be" ] || { echo "REDCARD bin=$BIN" > $R/out/b0_740_results.log; exit 3; }
# 电池热闸（口径=R-077 勘误）
t=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
n=0
while [ -n "$t" ] && [ "$t" -gt 440 ]; do
  n=$((n+1)); [ $n -gt 100 ] && { echo "GIVEUP_HOT $t" > $R/out/b0_740_results.log; exit 1; }
  sleep 30; t=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
done
rm -f $R/out/b0_740.log $R/out/b0_740.err
nohup timeout 2400 env E2E_TEMP=0 GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl $LOADER --library-path $LP $R/bin/minicpm_e2e_x4 $M $X 99 8 16 > $R/out/b0_740.log 2> $R/out/b0_740.err </dev/null &
wait $!
rc=$?
gpu=$(grep 'assigned to device' $R/out/b0_740.err | awk '$7 ~ /GPU|OpenCL/' | wc -l)
cpu=$(grep 'assigned to device' $R/out/b0_740.err | awk '$7 ~ /CPU/' | wc -l)
drv=$(grep -m1 -o '26\.[0-9.]*' $R/out/b0_740.err)
llvm=$(grep -c 'LLVM ERROR' $R/out/b0_740.err)
mt=$(grep -m1 METRIC $R/out/b0_740.log)
echo "RESULT b0_740 rc=$rc bin=$BIN gpu_layers=$gpu cpu_layers=$cpu drv=$drv llvm_err=$llvm $mt at=$(date +%H:%M:%S)" > $R/out/b0_740_results.log
