#!/system/bin/sh
# [Mesa 线 P2] 第二轮消融：换 FD_MESA_DEBUG 选项（部署 lib 里确认存在的两个），打"环增长/并发提交"这一族。
#
# 为什么换靶子（不是拍脑袋，是被上一轮实测逼的）：
#   1) 上游 sp 延迟提交合并（should_defer / flush_deferred_submits）**确实活着**：830 async 腿实测
#      numcmds=2 的提交 6040 次、numcmds=1 的 4221 次；`FD_NODEFER=1` 后 numcmds>=2 归零 => 开关是活的。
#   2) 但关掉合并**不改变正确性**：a0 与 a0_nodefer 都在第 1 个 token 就与 CPU 分歧、分歧率同为 98%，
#      而 flush1 两条腿（a1/a1_nodefer）与 CPU 49 token **逐 token 全等**。
#      => **"延迟提交合并"作为 gen7 kernel 丢失的根因，被实测否掉**（§5.1 记勘误）。
#   3) 同 workload 下 async 的 IB 总数 16,301 vs flush1 的 203,092（差 12 倍）=> 两种模式走的
#      环/IB 生命周期根本不是一条路；矛头从"合并"移到 **环复用与 grow**（sp 模型的 ringpool +
#      fd_ringbuffer_sp_grow：调 fd_bo_new_ring + fd_bo_map 换新环）。
#   4) 部署的那颗 lib 里，除 FD_NODEFER 外还有两个 fork 选项串：**`nogrow` 与 `inorder`**
#      （chroot 那颗旧 lib 里没有 FD_NODEFER，说明设备那颗更新；两颗 build-id 不同，已记为溯源事实）。
#      `nogrow` 的存在本身 = fork 作者也怀疑过 grow；`inorder` = 强制顺序提交。
#
# 判据（每条腿都过 token 尺子，参照 = 同 run 的 CPU 腿）：
#   · 某腿从"第 1 个 token 崩"变成"49 token 全等 PASS" => 那一族就是根因，P2 当场收口；
#   · 全部照旧崩 => 环/grow/并发也排除，下一刀只能上"能加探针的自建构"（P0-2 trace-off 构）；
#   · 任何腿起不来（tok=0）=> 该选项在本 workload 不可用，记录后继续，不阻塞其它腿。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_fddebug.sh [npred=48]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-48}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
OUT=/data/local/tmp/p2f_$(date +%H%M); mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。然后再分别说明印刷术在欧洲古登堡时期的改良、火药经阿拉伯传入欧洲的路径、指南针在宋代航海中的应用记载、造纸术对纸张成本的影响，各不少于六十字。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### fddebug npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"
echo "#### 部署 lib 选项串：FD_NODEFER=$(grep -ac FD_NODEFER $B/lib/libRusticlOpenCL.so 2>/dev/null) 另含 nogrow/inorder（见 §5.1 溯源）"

leg () { # $1=tag $2..=该腿 env（OPFLUSH 固定 0 = async，这才是病灶态）
  T=$1; shift
  echo "-- LEG $T OFL=0 [$*] $(date +%H:%M:%S)"
  env "$@" GGML_OPENCL_OPFLUSH=0 E2E_TOKDUMP=$OUT/$T.tok timeout 900 \
    ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? tok=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}')B submits=$(grep -ac 'KGSLSUBMIT ioctl' $OUT/$T.err 2>/dev/null) ibs=$(grep -ac 'KGSLSUBMIT cmd\[' $OUT/$T.err 2>/dev/null) merged=$(grep -acE 'numcmds=[2-9]' $OUT/$T.err 2>/dev/null) health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out)"
  sleep 60
}
env LD_LIBRARY_PATH=$RUN:$RUN/lib:/data/local/tmp GGML_OPENCL_OFF=1 GGML_OPENCL_OPFLUSH=0 \
  E2E_TOKDUMP=$OUT/cpu.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/cpu.out 2>$OUT/cpu.err
echo "-- LEG cpu rc=$? tok=$(ls -l $OUT/cpu.tok 2>/dev/null | awk '{print $5}')B"
sleep 60
leg base
leg inorder   FD_MESA_DEBUG=inorder
leg nogrow    FD_MESA_DEBUG=nogrow
leg both      FD_MESA_DEBUG=inorder,nogrow
leg nodefer2  FD_NODEFER=1 FD_MESA_DEBUG=inorder
echo "=== P2_FDDEBUG_DONE dir=$OUT ==="
echo "读法：python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu.tok $OUT/base.tok $OUT/inorder.tok $OUT/nogrow.tok $OUT/both.tok $OUT/nodefer2.tok"
echo "判据：任一腿 49 token 全等 PASS => 那一族（并发提交/环 grow）即 gen7 kernel 丢失根因，P2 收口"
echo "     全崩 => 环族也排除，下一刀只能自建带探针的 trace-off 构（P0-2）"
