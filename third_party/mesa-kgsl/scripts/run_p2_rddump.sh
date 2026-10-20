#!/system/bin/sh
# [Mesa 线 P2 直取证据] 用部署 lib 里确实存在的 FD_RD_DUMP* 开关，把两次跑的**提交流**落盘做离线差分。
#
# 为什么是这一发（§5.1c(5) 的下一步）：免重编的 env 开关已扫完 —— FD_NODEFER 能关掉提交合并
# （merged 6040→0）但改不动正确性；inorder/nogrow 两个串在提交路径上观测量逐位相同（等于没接）。
# 唯一能救 gen7 的仍是 ggml 侧逐 op flush。⇒ 想再往前，需要"async 到底少提交了哪些 CB"的**直接照片**，
# 而不是任何间接观测量。部署 lib 的字符串表里有 FD_RD_DUMP / FD_RD_DUMP_SUBMITS / FD_RD_DUMP_PATH /
# FD_RD_DUMP_FRAMES / FD_GPU_TRACEPOINT，这是 Mesa 的 replay-dump 机制，**不用重编就能开**。
#
# 判据（按能拿到什么分层，拿不到也要写清楚，不许把"没输出"当成"没差异"）：
#   A) dump 目录里有 per-submit 文件 ⇒ 对 async 与 flush1 两条流分别数 dispatch/CB 序列，
#      与 `KGSLSUBMIT cmd[] numcmds` 对齐；async 少掉的 CB = kernel 丢失的正面证据。
#   B) 只有帧级 dump ⇒ 至少能比对两次的帧内 draw/dispatch 计数。
#   C) 目录为空 ⇒ 该开关在这颗 fork 里没接 kgsl 路径，记为"直取证据路线关闭"，回到 P0-2 自建构。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_rddump.sh [npred=24]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-24}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
STAMP=$(date +%H%M); OUT=/data/local/tmp/p2r_$STAMP; mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### rddump npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

leg () { # $1=tag $2=OPFLUSH $3..=额外 env
  T=$1; OF=$2; shift 2
  D=$OUT/dump_$T; mkdir -p $D
  echo "-- LEG $T OFL=$OF [$*] dump=$D $(date +%H:%M:%S)"
  env FD_RD_DUMP=1 FD_RD_DUMP_SUBMITS=1 FD_RD_DUMP_PATH=$D "$@" GGML_OPENCL_OPFLUSH=$OF \
    E2E_TOKDUMP=$OUT/$T.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? tok=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}')B submits=$(grep -ac 'KGSLSUBMIT ioctl' $OUT/$T.err 2>/dev/null) ibs=$(grep -ac 'KGSLSUBMIT cmd\[' $OUT/$T.err 2>/dev/null) merged=$(grep -acE 'numcmds=[2-9]' $OUT/$T.err 2>/dev/null) health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out)"
  echo "   dump 内容：文件数=$(find $D -type f 2>/dev/null | wc -l) 总字节=$(du -sk $D 2>/dev/null | cut -f1) 顶层=$(ls $D 2>/dev/null | head -4 | tr '\n' ' ')"
  sleep 60
}
leg async 0
leg flush1 1
echo '-- 顺便验一下 dump 相关串还在不在（防止把"没触发"误判成"没差异"）：'
for s in FD_RD_DUMP FD_RD_DUMP_SUBMITS FD_RD_DUMP_PATH FD_GPU_TRACEPOINT; do printf "   %-20s %s\n" $s "$(grep -ac $s $B/lib/libRusticlOpenCL.so 2>/dev/null)"; done
echo "=== P2_RDDUMP_DONE dir=$OUT ==="
echo "读法：adb pull $OUT 后按判据 A/B/C 分层判读；async 与 flush1 两条流的 CB/dispatch 序列差分是本轮目标"
