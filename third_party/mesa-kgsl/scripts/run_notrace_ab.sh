#!/system/bin/sh
# [Mesa 线 P0-2 替代路径] trace-off A/B：同一条 Mesa 腿，加/不加 LD_PRELOAD=libnotrace.so，交错跑。
#
# 要回答两个问题（顺序不能反）：
#   1) **行为中性门**：吞掉 trace 打印之后，token 序列必须与不吞**逐 token 全等**（token_diff.py）。
#      不等 = 这个垫片改变了行为（或 Mesa 的打印与状态有耦合），立刻禁用，不许引用它测出的任何速度。
#   2) **打印税实测**：tok/s 的差就是 trace 打印在真工作量上的成本，用来替换 §2.5.3 里合成量具估的
#      1.4%~4.7%。注意：垫片只剥 printf，调试版若还编进别的跟踪逻辑，这里剥不掉 —— 报告必须这么写。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_notrace_ab.sh [npred=128] [rounds=2]
set -u
BIN=${BIN:-minicpm_e2e}   # 设备上有多个构时必显式指定，否则悄悄跑成旧构
NPRED=${1:-128}; ROUNDS=${2:-2}
RUN=${RUN:-/data/local/tmp/k40moe}; B=${B:-/data/local/tmp/mesa_clean}
M=${M:?需要 M=<gguf>}
E=${E:?需要 E=<experts 目录>}
NT=${NT:-/data/local/tmp/libnotrace.so}
OUT=/data/local/tmp/ntab_$(date +%H%M); mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0.7
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### notrace_ab npred=$NPRED rounds=$ROUNDS $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

leg () { # $1=tag $2=preload($NT 或空) $3..=其它 env
  T=$1; PRE=$2; shift 2
  echo "-- LEG $T preload=[$PRE] $* $(date +%H:%M:%S)"
  env LD_PRELOAD="$PRE" "$@" E2E_TOKDUMP=$OUT/$T.tok timeout 900 \
    ./$BIN "$M" "$E" 99 "$NPRED" 512 2>/dev/null > $OUT/$T.out
  echo "   rc=$? tok=$(grep -aoE 'tok_s=[0-9.]+' $OUT/$T.out | tail -1) tokbytes=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}') nt=$(grep -aoE 'swallowed=[0-9]+' $OUT/$T.out | tail -1)"
  sleep 90
}
r=1
while [ $r -le "$ROUNDS" ]; do
  echo "=== ROUND $r / $ROUNDS ==="
  leg f1_off_r$r ""     GGML_OPENCL_OPFLUSH=1
  leg f1_on_r$r  "$NT"  GGML_OPENCL_OPFLUSH=1
  leg f0_off_r$r ""     GGML_OPENCL_OPFLUSH=0
  leg f0_on_r$r  "$NT"  GGML_OPENCL_OPFLUSH=0
  r=$((r+1))
done
echo "=== NOTRACE_AB_DONE dir=$OUT ==="
echo "门 1：adb pull $OUT 后 python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/f1_off_r1.tok $OUT/f1_on_r1.tok $OUT/f0_off_r1.tok $OUT/f0_on_r1.tok"
echo "门 2：每条 _on_ 腿的 nt=swallowed 必须 >0；为 0 说明覆盖没生效，本组速度全部作废"
