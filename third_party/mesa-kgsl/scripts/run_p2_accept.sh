#!/system/bin/sh
# [Mesa 线 P2 验收] 逐 token 一致性：CPU 参照 vs Mesa 各提交策略，同一 seed/temp。
# 判据（写死在总档）：OPFLUSH=0 与 CPU 参照 48 token 全等 = 提交层 kernel 丢失修好。
# 取数后用 host 侧 scripts/token_diff.py 比对（E2E_TOKDUMP 落 i32 序列）。
# 用法：sh run_p2_accept.sh [n_predict=48] [legs=cpu,flush1,async,flush2]
set -u
NPRED=${1:-48}
LEGS=${2:-cpu,flush1,async,flush2}
RUN=${RUN:-/data/local/tmp/mesa_run}; B=${B:-/data/local/tmp/mesa_bionic}
M=${M:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf}
E=${E:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts}
TOK=/data/local/tmp/p2tok_$(date +%H%M); mkdir -p $TOK
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1
unset FD_NODEFER FD_NO_BOCACHE FD_FORCE_REEMIT FD_KGSL_TSSYNC FD_COMPUTE_WFI FD_IBTRACE FD_MESA_DEBUG FD_KGSL_USLEEP_US
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### accept npred=$NPRED legs=$LEGS temp=0 seed=42 $(date -Iseconds)"
one () { # $1=name $2..=env
  N=$1; shift
  echo "-- LEG $N $(date +%H:%M:%S) env=$*"
  env "$@" E2E_TOKDUMP=$TOK/$N.bin timeout 900 ./minicpm_e2e "$M" "$E" 99 "$NPRED" 512 > $TOK/$N.out 2>/dev/null
  echo "   rc=$? tok=$(grep -aoE 'tok_s=[0-9.]+' $TOK/$N.out | tail -1) bytes=$(ls -l $TOK/$N.bin 2>/dev/null | awk '{print $5}')"
  sleep 60
}
case ",$LEGS," in *,cpu,*)   one cpu     GGML_OPENCL_OFF=1 GGML_OPENCL_OPFLUSH=0 ;; esac
case ",$LEGS," in *,flush1,*) one flush1  GGML_OPENCL_OPFLUSH=1 ;; esac
case ",$LEGS," in *,flush2,*) one flush2  GGML_OPENCL_OPFLUSH=2 ;; esac
case ",$LEGS," in *,async,*)  one async   GGML_OPENCL_OPFLUSH=0 ;; esac
echo "=== ACCEPT_DONE tokdir=$TOK ==="
