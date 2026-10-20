#!/system/bin/sh
# [Mesa 线 P2-0] 压力复现器：目标是**在调试机（K40/gen6）上把 async 的 kernel 丢失逼出来**。
#
# 为什么值得做：丢失目前只在 830(gen7) 见过，而那台机器偶尔掉线、还被别的会话抢。
# 若能在 K40 上稳定复现，P2 就从"考古"变成"能天天迭代"。压力维度按"什么会让未 flush 的
# 积压更深 / GPU 更慢消费 / 宿主更慢提交"来选：
#   NBATCH↑   每个内核更大 → GPU 消费更慢 → 队列更深
#   NPRED↑    更多解码步 → 更多机会暴露
#   IO 线程↑  专家 pread 与提交线程抢 CPU/总线
#   NOMMAP=0  走 mmap → 页缓存回收抢内存
#   FORCE_SEQ 长教师序列 → 单次 graph 的节点数与内核工作量都更大
# 判定：与**同配置 CPU 参照**逐 token 比（scripts/token_diff.py）。只要有一条 async 腿
#       "首个分歧位置"明显早于同配置 flush1 腿，就算复现成功。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_pressure.sh [npred=128]
set -u
NPRED=${1:-128}
RUN=${RUN:-/data/local/tmp/k40moe}; B=${B:-/data/local/tmp/mesa_clean}
M=${M:?需要 M=<gguf 路径>}
E=${E:?需要 E=<experts 目录>}
OUT=/data/local/tmp/p2p_$(date +%H%M); mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。然后再分别说明印刷术在欧洲古登堡时期的改良、火药经阿拉伯传入欧洲的路径、指南针在宋代航海中的应用记载、造纸术对纸张成本的影响，各不少于六十字。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### pressure npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

leg () { # $1=tag $2=OPFLUSH $3..=env
  T=$1; OF=$2; shift 2
  echo "-- LEG $T OFL=$OF $* $(date +%H:%M:%S)"
  env "$@" GGML_OPENCL_OPFLUSH=$OF E2E_TOKDUMP=$OUT/$T.tok timeout 900 \
    ./minicpm_e2e "$M" "$E" 99 "$NPRED" 512 > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? tokbytes=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}') sub=$(grep -ac 'KGSLSUBMIT cmd\[' $OUT/$T.err 2>/dev/null) health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out)"
  sleep 60
}

BASE="E2E_NBATCH=512 E2E_NOMMAP=1 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1"
CPU="GGML_OPENCL_OFF=1"

# 参照 + 基线
leg cpu_base      0 $CPU $BASE
leg f1_base       1 $BASE
leg f0_base       0 $BASE
# 加压：大批次
leg f0_nb2048     0 E2E_NBATCH=2048 E2E_NOMMAP=1 LLAMA_MOE_IO_THREADS=1 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0
leg f1_nb2048     1 E2E_NBATCH=2048 E2E_NOMMAP=1 LLAMA_MOE_IO_THREADS=1 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0
# 加压：IO 并发
leg f0_io4        0 E2E_NBATCH=512 E2E_NOMMAP=1 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_DECODE_WINDOW=16 LLAMA_MOE_LOOKAHEAD_PREFETCH=16 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0
# 加压：mmap（走页缓存）
leg f0_mmap       0 E2E_NBATCH=512 E2E_NOMMAP=0 LLAMA_MOE_IO_THREADS=1 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0
# 加压：大批次 + IO 并发 + mmap 三管齐下
leg f0_all        0 E2E_NBATCH=2048 E2E_NOMMAP=0 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_DECODE_WINDOW=16 LLAMA_MOE_LOOKAHEAD_PREFETCH=16 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0
leg f1_all        1 E2E_NBATCH=2048 E2E_NOMMAP=0 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_DECODE_WINDOW=16 LLAMA_MOE_LOOKAHEAD_PREFETCH=16 LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0
echo "=== P2_PRESSURE_DONE dir=$OUT ==="
echo "取数：adb pull $OUT 后 python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu_base.tok $OUT/f0_*.tok $OUT/f1_*.tok"
