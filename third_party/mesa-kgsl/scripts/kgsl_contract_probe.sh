#!/system/bin/sh
# [网格 G-208 / 架构动作 A] KGSL 提交层契约探针 —— **两线共用**判具（OpenCL 线 与 Vulkan 线同时跑）
#
# 为什么需要它：两条线在 L1（KGSL 内核驱动）是同一个物理对象，在 L2 却是两份互不相通的代码
#   （OpenCL 线 = 我们自己的 kgsl winsys + FD_* 探针；Vulkan 线 = turnip 的 tu_knl_kgsl）。
#   到今天为止，**没有任何一发实验同时覆盖过两边的提交层**，所以 OpenCL 线在 P2 上烧掉的六次假设搬家，
#   对 Vulkan 线的 L2 零传递；反过来 Vulkan 线今天靠数据表拿下的东西也帮不到 OpenCL 线。
#
# 本判具的规矩（照网格 R3 写死，不许绕）：
#   **Phase 1 是闸门**：先证明每一侧的"提交证据通路"是接通的，并把结果落成 接通/未接通。
#   任何一侧 Phase 1 未接通 => 该侧 Phase 2 **拒绝出数**，状态记 `未观测`，
#   **永远不许把"没打印"读成"没差别"**（这条教训来自 FD_MESA_DEBUG=inorder 与 FD_RD_DUMP 两次假清白）。
#
# 契约断言（两侧必须给同一个形状的答案）：
#   C1 enqueued == submitted            每个入队的 compute 都进了提交
#   C2 submitted 的每笔都有 timestamp    提交被 GPU 受理（KGSL timestamp 前进）
#   C3 max(sizedwords) vs 环容量          深队列时是否顶到上限（G-201 的直接判据）
#   C4 每笔提交都有 out-fence 且被 signal fence 语义没被跳过
#   C5 积压深度 vs 丢失率曲线              OPFLUSH 扫档，找"从第几个 op 开始丢"
#
# 用法：sh kgsl_contract_probe.sh [phase1|phase2|all]
#   可调：VK_DIR=/data/local/tmp/vkl  CL_RUN=/data/local/tmp/k40moe  CL_B=/data/local/tmp/mesa_clean
#         CL_M=<gguf>  CL_E=<experts>  VK_M=<gguf>  NPRED=64  OFL_LIST="0 1 2 4 8"
set -u
MODE=${1:-all}
VK_DIR=${VK_DIR:-/data/local/tmp/vkl}
CL_RUN=${CL_RUN:-/data/local/tmp/k40moe}
CL_B=${CL_B:-/data/local/tmp/mesa_clean}
CL_M=${CL_M:-$CL_RUN/models/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf}
CL_E=${CL_E:-$CL_RUN/models/experts}
VK_M=${VK_M:-$VK_DIR/Ling-3.0-tiny-Q4_0.gguf}
NPRED=${NPRED:-64}
OFL_LIST=${OFL_LIST:-"0 1 2 4 8"}
STAMP=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-/data/local/tmp/kgsl_contract_$STAMP}; mkdir -p $OUT
DEV=$(getprop ro.product.model 2>/dev/null); GEN=$(getprop ro.board.platform 2>/dev/null)

have () { [ -e "$1" ]; }
say () { echo "$@" | tee -a $OUT/report.txt; }

say "#### KGSL 提交层契约探针  model=$DEV board=$GEN  $(date -Iseconds)"
say "#### loadavg=$(cat /proc/loadavg)  temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"

# ============================ Phase 1：仪器接通性 ============================
p1=$OUT/phase1.txt; : > $p1
say ""; say "===== Phase 1：证据通路接通性（这一节不通，Phase 2 不出数）====="

# --- 内核侧（两线共用，最有价值的中立证据源：不依赖任何一条线的驱动补丁）---
KGSL_SYS=/sys/class/kgsl/kgsl-3d0
say "[kernel] $KGSL_SYS: $(have $KGSL_SYS && echo 接通 || echo 不存在)"
for f in gpu_busy num_contexts gmu_platform device_gid; do
  have $KGSL_SYS/$f && say "  - $f = $(cat $KGSL_SYS/$f 2>/dev/null | head -1)  (接通)"
done
have $KGSL_SYS/num_contexts && TS0=$(cat $KGSL_SYS/num_contexts 2>/dev/null)
say "[kernel] debugfs kgsl: $(have /sys/kernel/debug/kgsl && echo 接通 || echo '未接通（非 root 常见）')"
say "[kernel] ftrace kgsl events: $(ls /sys/kernel/debug/tracing/events/kgsl 2>/dev/null | tr '\n' ' ')"
[ -d /sys/kernel/debug/tracing/events/kgsl ] && say "  => 接通：可用 tracepoint 作两线中立计数器（G-205 EAGAIN 那条就靠它）"

# --- OpenCL 侧：FD_* 探针串在 lib 里不等于通路在，必须实测它真的会打印 ---
CLLIB=$CL_B/lib/libRusticlOpenCL.so
say "[cl] lib=$CLLIB md5=$(md5sum $CLLIB 2>/dev/null | awk '{print $1}')"
for s in KGSLSUBMIT FDBATCH BORERELEASE CSDESC FDFINAL; do
  have $CLLIB && strings -a $CLLIB 2>/dev/null | grep -qa "$s" \
    && say "  - 串 $s 在 lib 里（**仅证明编进去了，不证明会打印**）" \
    || say "  - 串 $s 不在 lib 里"
done
say "[cl] 探针实打验证放到 Phase 2（跑一条最短腿，数 stderr 里 KGSLSUBMIT 行数 > 0 才算接通）"

# --- Vulkan 侧：turnip 的调试通路是什么，先问它自己，别猜 ---
if [ -d "$VK_DIR" ]; then
  say "[vk] VK_DIR=$VK_DIR  turnip md5=$(md5sum $VK_DIR/libturnip_freedreno.so 2>/dev/null | awk '{print $1}')"
  say "[vk] 问 turnip 自己支持哪些 debug 位（别照抄别人的 TU_DEBUG）:"
  ( cd $VK_DIR && TU_DEBUG=help LD_LIBRARY_PATH=$VK_DIR timeout 20 ./llama-cli --help >/dev/null 2>$OUT/tu_help.err; \
    grep -aiE 'debug|queue|submit|trace' $OUT/tu_help.err | head -8 | sed 's/^/    /' )
  say "[vk] MESA_DEBUG 亦试: $(MESA_DEBUG=help env 2>&1 | grep -aiE 'debug' | head -3 | tr '\n' '|')"
else
  say "[vk] $VK_DIR 不存在 => Vulkan 侧仪器未接通，Phase 2 只出 OpenCL 半边"
fi

# ============================ Phase 2：同一压测打两侧 ============================
if [ "$MODE" = "phase1" ]; then say ""; say "=== 只跑 Phase 1，结束。dir=$OUT ==="; exit 0; fi

say ""; say "===== Phase 2：同一提交压测，两侧各跑一次 ====="

cl_leg () { # $1=OPFLUSH
  OFL=$1; T=cl_ofl$OFL
  say "-- $T $(date +%H:%M:%S) load=$(cut -d' ' -f1 /proc/loadavg)"
  ( cd $CL_RUN && env LD_LIBRARY_PATH=$CL_RUN:$CL_RUN/lib:$CL_B/lib:$CL_B:/data/local/tmp \
      OCL_ICD_VENDORS=$CL_B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl \
      HOME=$CL_B/tmp XDG_CACHE_HOME=$CL_B/tmp CLC_RESOURCE_DIR=$CL_B/lib/clang/21/include \
      GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1 \
      GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0 \
      GGML_OPENCL_OPFLUSH=$OFL \
      E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0 \
      timeout 900 ./minicpm_e2e_dspark "$CL_M" "$CL_E" 99 "$NPRED" 512 \
      > $OUT/$T.out 2> $OUT/$T.err )
  SUB=$(grep -ac 'KGSLSUBMIT' $OUT/$T.err); BOR=$(grep -ac 'BORERELEASE' $OUT/$T.err)
  PEAK=$(grep -aoE 'FDBATCH flush:.*size=[0-9]+' $OUT/$T.err | awk -Fsize= '{print $2}' | sort -n | tail -1)
  say "   C1/C3: submits=$SUB bo_release=$BOR max_sizedwords=${PEAK:-未取到}"
  # 仪器接通闸：一条腿里连一行 KGSLSUBMIT 都没有 => 探针没通，本腿不作数
  [ "$SUB" -eq 0 ] && say "   !! 仪器闸失败：KGSLSUBMIT 行数=0，该腿记 `未观测`，不得据此说提交层没差别"
  grep -a 'e2e\]\[METRIC' $OUT/$T.out | tail -1 | grep -aoE 'gen=[0-9]+ wall_ms=[0-9]+ tok_s=[0-9.]+' | sed 's/^/   perf: /'
  sleep ${COOLDOWN:-45}
}

vk_leg () {
  T=vk_base
  [ -d "$VK_DIR" ] || { say "-- $T 跳过（Vulkan 侧未接通）"; return; }
  say "-- $T $(date +%H:%M:%S) load=$(cut -d' ' -f1 /proc/loadavg)"
  ( cd $VK_DIR && env LD_LIBRARY_PATH=$VK_DIR TU_DEBUG=${TU_DEBUG:-queue} \
      GGML_VK_TURNIP=$VK_DIR/libturnip_freedreno.so \
      timeout 900 ./llama-cli -m "$VK_M" -dev Vulkan0 -ngl 99 -fa off -p "$VK_PROMPT" \
      -n "$NPRED" -c 1024 -st --no-display-prompt --temp 0 -s 42 \
      > $OUT/$T.out 2> $OUT/$T.err )
  SUB=$(grep -acE 'submit|Submit' $OUT/$T.err)
  say "   C1/C2: vk_submit_lines=$SUB（**先确认 Phase 1 里 TU_DEBUG 真能打出东西**，否则记 未观测）"
  grep -aoE '[0-9]+\.[0-9]+ tokens per second' $OUT/$T.out | tail -1 | sed 's/^/   perf: /'
}

VK_PROMPT=${VK_PROMPT:-'请详细介绍一下中国的四大发明，分四段展开。'}
TS0=$(cat $KGSL_SYS/num_contexts 2>/dev/null)
for O in $OFL_LIST; do cl_leg $O; done
vk_leg
TS1=$(cat $KGSL_SYS/num_contexts 2>/dev/null)
say ""; say "[kernel] num_contexts: ${TS0:-?} -> ${TS1:-?}"

say ""; say "=== KGSL_CONTRACT_DONE dir=$OUT ==="
say "读法：把 cl 各档的 submits/max_sizedwords 与 vk 腿的 submit 计数并排放同一张表；"
say "     两侧必须能回答同一条 C1（入队==提交）。哪一侧的仪器闸失败，那一侧就写 未观测，不写无罪。"
say "     本判具的首跑产出应直接填进 docs/Mesa与Vulkan线_架构问题网格 的 G-208/G-201/G-205 三格。"
