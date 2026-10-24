#!/usr/bin/env bash
# run_g725_gate.sh —— 一发定案 G-725：batched MoE 到底被哪道闸挡回 dense-loop。
#
# 背景：`ggml_cl_mul_mat_id_batched` 的 7 个拒收点全是裸 `return false`，一行日志不打
# （Ling 3.0 Tiny 专档 §0 的定案），所以"自研 batched 内核从未被派发"这种事静态审计定不了。
# 本腿用带只读计数器的构建（_probe 构，git/dirty 指纹入日志头）跑一发 MiniCPM Mesa 腿，
# 直接打印每道闸的命中数 + DISPATCHED_batched 是否 > 0。
#
# env 逐字照抄 run_mesa_matrix.sh:45 的 MESA_ENV（同一条腿的其它开关不许漂），
# 只加 GGML_OPENCL_MOE_GATE_STATS=1（+ GGML_MOE_TRACE=1 作交叉核对）。
set -u
DEV=${DEV:-100.67.150.120:5555}
RUNDIR=${RUNDIR:-/data/local/tmp/g725_run}          # 新目录：绝不覆盖在跑的 mesa_run
B=${B:-/data/local/tmp/mesa_bionic}
M=${M:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf}
E=${E:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts}
NGL=${NGL:-99} NPRED=${NPRED:-32}
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
BINHOST="$REPO/_probe/moe_probe/build-android/minicpm_e2e"
STUBHOST="$REPO/_probe/moe_probe/build-android/libopencl_stub.so"

[ -x "$BINHOST" ] || { echo "!! 先跑 third_party/mesa-kgsl/scripts/build_probes_android.sh" >&2; exit 2; }

LA=$(adb -s "$DEV" shell cat /proc/loadavg | awk '{print $1}')
if [ "$(awk -v l="$LA" 'BEGIN{print (l+0<2)?1:0}')" != "1" ]; then
  echo "REFUSE: loadavg(1min)=$LA >= 2，机器不安静，本次不出数（宁可不出数）"; exit 3
fi

adb -s "$DEV" shell "mkdir -p $RUNDIR" >/dev/null
adb -s "$DEV" push "$BINHOST" "$RUNDIR/minicpm_e2e_g725" >/dev/null
adb -s "$DEV" push "$STUBHOST" "$RUNDIR/libopencl_stub.so" >/dev/null
adb -s "$DEV" shell "chmod 755 $RUNDIR/minicpm_e2e_g725"

LOG="$RUNDIR/gate_$(date +%H%M).log"
echo "== 构建指纹（R7：无指纹的数不入档）=="
cat "$REPO/_probe/moe_probe/build-android/BUILD_INFO" 2>/dev/null | sed 's/^/   /'
echo "== 起跑 loadavg=$LA NGL=$NGL NPRED=$NPRED =="

# 在役配置的所有 LLAMA_MOE_* 开关照抄矩阵脚本（G-713 那条教训：工装硬 export 会静默钉死取值，
# 所以这里把用到的开关全部显式写出来，不靠继承）
adb -s "$DEV" shell "
  LD_LIBRARY_PATH=$RUNDIR:$B/lib:/data/local/tmp \
  OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl \
  HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include \
  GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1 GGML_OPENCL_MESA_SPIRV=1 \
  GGML_OPENCL_ADRENO_XMEM_GEMM=0 \
  LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6 \
  LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1 \
  GGML_OPENCL_MOE_GATE_STATS=1 GGML_MOE_TRACE=1 \
  E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0.7 \
  GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结' \
  timeout 900 $RUNDIR/minicpm_e2e_g725 '$M' '$E' $NGL $NPRED 512 > $LOG 2>&1; \
  echo RC=\$?; grep -ac . $LOG | sed 's/^/log_lines=/'"

echo "== 判定行 =="
adb -s "$DEV" shell "grep -a 'moe-gate' $LOG | tail -3; echo '--- 交叉核对 ---'; grep -acE 'moe_q3k_pack|batched' $LOG | sed 's/^/pack_or_batched_lines=/'; grep -aE 'split-moe|slot bank|tok_s|E2E' $LOG | tail -6" 2>&1

# R8(h) 结构必录：图被切成几段（splits）是漂移免疫的结构性回归指标，G-759 那次 3 天 regression
# 就是因为没人录它。缺任何一项，这条腿作废，不许进档。
echo "== 结构必录（R8(h)：缺一项该腿作废）=="
PLAT=$(adb -s "$DEV" shell "grep -a 'selected platform' $LOG | tail -1" 2>&1 | tr -d '\r')
NODES=$(adb -s "$DEV" shell "grep -aoE 'nodes = [0-9]+' $LOG | tail -1" 2>&1 | tr -d '\r')
SPLITS=$(adb -s "$DEV" shell "grep -aoE 'splits = [0-9]+' $LOG | tail -1" 2>&1 | tr -d '\r')
OFFL=$(adb -s "$DEV" shell "grep -aoE 'offloaded [0-9]+/[0-9]+ layers' $LOG | tail -1" 2>&1 | tr -d '\r')
printf '   %s\n   %s\n   %s\n   %s\n' "${PLAT:-缺 selected platform}" "${NODES:-缺 nodes}" "${SPLITS:-缺 splits}" "${OFFL:-缺 offloaded}"
for need in "$PLAT" "$NODES" "$SPLITS" "$OFFL"; do
  [ -n "$need" ] || { echo "   => 结构字段不全，该腿作废（R8(h)）"; exit 1; }
done

echo "日志留在设备：$DEV:$LOG"
