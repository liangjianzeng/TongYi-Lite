#!/system/bin/sh
# [Mesa 线 P2 决定性实验] 关掉上游"延迟提交合并"（deferred submits），看 gen7 的 kernel 丢失是否消失。
#
# 依据（§5.1，上游 Mesa 26.2.4 实读 + fork 已安装产物反汇编）：
#   freedreno_ringbuffer_sp.c:309 should_defer() 的上游注释自己写着
#   "with 32K ringbuffer, we have an upper limit of 2k cmds before we exceed the size of
#    the ringbuffer, which results in deadlock writing into the RB (ie. kernel doesn't
#    finish writing into the RB so it doesn't kick the GPU to start consuming from the RB)"
#   —— 那是按 **msm** 的环尺寸写的；kgsl 下游内核的 drawctxt 环与 IB 记账完全不同。
#   "enqueued 271390 > submitted 118586、ioctl 返回 0、GPU 没被 kick、kernel 静默消失"
#   正是这段注释描述的事故。决策点 :381 是 `!use_fence_fd && !has_shared && should_defer()`，
#   rusticl 的 in-order 队列 + 无事件正好把前两个条件都放行。
#
# 判据（两条都要，缺一不可）：
#   A) 开关活着：async 腿加 FD_NODEFER=1 后 `sub=`（KGSLSUBMIT 次数）必须明显上涨，
#      向 flush1 的量级靠拢。不涨 = 这个 env 在部署的那颗 lib 里不存在/没接上，本组全作废。
#   B) 病灶判定：**830(gen7)** 上 `async + FD_NODEFER=1` 与 CPU 参照逐 token 全等（48 token），
#      而 `async` 单独跑仍崩 => 根因 = 延迟提交合并与 kgsl 环记账冲突（修法：winsys 里
#      按 kgsl 环容量决定 should_defer，或直接禁合并）。
#   K40(gen6) 上 B 预计两条都过（它本来就不丢），这里只当 A 的验枪 + 反证"禁合并不会引入新问题"。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_nodefer.sh [npred=48]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-48}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
OUT=/data/local/tmp/p2n_$(date +%H%M); mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。然后再分别说明印刷术在欧洲古登堡时期的改良、火药经阿拉伯传入欧洲的路径、指南针在宋代航海中的应用记载、造纸术对纸张成本的影响，各不少于六十字。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### nodefer npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"
echo "#### 部署 lib 里有没有 FD_NODEFER：$(grep -ac FD_NODEFER $B/lib/libRusticlOpenCL.so 2>/dev/null)"

leg () { # $1=tag $2=OPFLUSH $3..=env
  T=$1; OF=$2; shift 2
  echo "-- LEG $T OFL=$OF [$*] $(date +%H:%M:%S)"
  env "$@" GGML_OPENCL_OPFLUSH=$OF E2E_TOKDUMP=$OUT/$T.tok timeout 900 \
    ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? tok=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}')B sub=$(grep -ac 'KGSLSUBMIT cmd\[' $OUT/$T.err 2>/dev/null) health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out)"
  sleep 60
}
# CPU 参照（同一 prompt / 同一构），再四种组合
env LD_LIBRARY_PATH=$RUN:$RUN/lib:/data/local/tmp GGML_OPENCL_OFF=1 GGML_OPENCL_OPFLUSH=0 \
  E2E_TOKDUMP=$OUT/cpu.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/cpu.out 2>$OUT/cpu.err
echo "-- LEG cpu rc=$? tok=$(ls -l $OUT/cpu.tok 2>/dev/null | awk '{print $5}')B"
sleep 60
leg a0          0
leg a0_nodefer  0    FD_NODEFER=1
leg a1          1
leg a1_nodefer  1    FD_NODEFER=1
echo "=== P2_NODEFER_DONE dir=$OUT ==="
echo "读法：python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu.tok $OUT/a0.tok $OUT/a0_nodefer.tok $OUT/a1.tok $OUT/a1_nodefer.tok"
echo "门 A（开关活着）：a0_nodefer 的 sub 必须明显大于 a0 的 13817 量级；不涨就整组作废"
echo "门 B（病灶）：830 上 a0 崩而 a0_nodefer 与 cpu 全等 => 根因定为延迟提交合并"
