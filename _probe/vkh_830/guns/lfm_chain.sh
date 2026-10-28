R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LGM=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
LOG=$R/out/chain.log
run_leg() {
  TAG=$1; NGL=$2; NPRED=$3; MODEL=$4; shift 4
  timeout 1500 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors GGML_OPENCL_HOST_TIMING=1 "$@" $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $MODEL $NPRED $NGL 42 > $R/out/$TAG.tok 2> $R/out/$TAG.err
  echo "#### $TAG rc=$? tokmd5=$(md5sum $R/out/$TAG.tok | cut -c1-8)" >> $LOG
  grep -aE 'METRIC|PHASE|CRASH|FAIL' $R/out/$TAG.err | tail -5 >> $LOG
  grep -ac 'kernel compile error' $R/out/$TAG.err | sed "s/^/$TAG kcerr=/" >> $LOG
}
echo "#### CHAIN start $(date +%T)" > $LOG
echo "preflight temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1) stayon=$(settings get global stay_on_while_plugged_in)" >> $LOG
echo "mem: $(grep -E 'MemTotal|MemAvailable' /proc/meminfo | tr '\n' ' ')" >> $LOG
logcat -c -b crash 2>/dev/null
# ling 双件核身（兄弟830"真主vkl"案 vs 我 g759 基线族；md5 相同=同物零争议）
echo "lingid g759=$(md5sum /data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf 2>/dev/null | cut -c1-8) vkl=$(md5sum /data/local/tmp/vkl/Ling-3.0-tiny-Q4_0.gguf 2>/dev/null | cut -c1-8)" >> $LOG
# ① ling CPU gold 新栈（子令②判别器）
run_leg l16 0 32 $LGM
# ② ling GPU 全武新栈回归
run_leg l15 99 32 $LGM GGML_OPENCL_MOE_SELFBUILD=1 GGML_OPENCL_FA_A7X_GUARD=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1 GGML_OPENCL_A7X_LMHEAD_CPU=0 GGML_OPENCL_SMART_DRAIN=1
# ③ LFM CPU gold（ssm_conv CPU 路审判）
run_leg lfmcpu 0 32 $M
# ④ LFM loadonly ngl=6（核编译+部分 GPU 装载验，内存安全）
run_leg lfml6 6 1 $M
# ⑤ LFM GPU 首腿 ngl=6 全武+A路
run_leg lfmg6 6 32 $M GGML_OPENCL_MOE_SELFBUILD=1 GGML_OPENCL_FA_A7X_GUARD=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1 GGML_OPENCL_A7X_LMHEAD_CPU=0 GGML_OPENCL_MOE_VIEW_SLOT=1 GGML_OPENCL_SMART_DRAIN=1 GGML_OPENCL_MOE_DEBUG=1
# ⑥ 4B CPU gold ×2（非确定性判别器：稳=GPU核级非实锤 / 不稳=采样参数面）
B4M=/data/local/tmp/g759/qwen35-4b-q4km.gguf
run_leg l4bg1 0 32 $B4M
run_leg l4bg2 0 32 $B4M
logcat -b crash -d -t 200 > $R/out/chain_crash.txt 2>&1
echo "#### CHAIN done $(date +%T)" >> $LOG
