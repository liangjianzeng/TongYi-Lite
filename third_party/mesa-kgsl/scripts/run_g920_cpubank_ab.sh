#!/system/bin/sh
# [网格 G-920] CPU bank 对手数到底是什么 —— 这格不定，整条线的每条 A/B 都站在流沙上。
#
# 为什么单独一件判具打它：
#   接管复评 §2.5 把"同一颗二进制 CPU bank 3.44 t/s vs 早上 7.00 t/s"记成 **「差 2 倍未归因」**，
#   候选给了 冷热节流 / ngl=0vs99 / 10-18 旧库 三条；而 主线遗留备忘 §F（同一天更早）已写明
#   **CPU bank 对手数由 LLAMA_MOE_IO_THREADS 主导（IO=1/W8/LA8 = 7.00，IO=4 -> 3.0-4.2）**，
#   那三条候选里没有它。更要命的是 run_mesa_matrix.sh:39 的 CPU 腿本来就设 IO_THREADS=1，
#   按备忘该复现 7.00，实测却只有 3.14（§5.2 裁决级）=> **备忘那个 7.00 自己也没有三元组**。
#   两个数谁也关不掉这格，只能同机同二进制重测。
#
# 本判具一次性把这事钉死：只跑 CPU 腿（不碰 Mesa，省 GPU 争抢），扫 IO_THREADS，
# 顺带带上 P8 采纳的 DECODE_WINDOW=64+ROUTE_KEEP=1 看 CPU 腿是否也吃它。
#
# 口径（照 §5.2 的裁决级规格，一条不松）：
#   安静态门 loadavg(1min) > 2 直接拒绝出数；交错（外层轮次，内层腿序固定）；每配置 3 轮；
#   腿间冷却 90s；每条腿都记 loadavg 与电池温度（冷热是候选之一，必须留痕）；
#   **CPU 身份硬闸**：opencl_lines 必须 == 0，>0 说明这条腿偷偷挂上了 Mesa，是假 CPU 数，作废；
#   E2E_TOKDUMP 只作留痕与"没崩、没乱码"的粗筛 —— 本判具刻意沿用 §5.2 的 E2E_TEMP=0.7，
#   有采样就没有逐位可复现，别拿 token 全等当尺子（那是 run_p2_accept 的活）。
# 判据：某配置三轮中位相对 io1 提升 >=5% 且三轮同号 => 该配置是对手数的主控变量；
#       若 IO_THREADS 各档彼此差 >=20% => 备忘 §F 成立，"7.00 那个数"从此按 IO 档标注，
#       任何不带 IO 档的 CPU bank 数一律不得引用。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_g920_cpubank_ab.sh [npred=128] [rounds=3]
set -u
BIN=${BIN:-minicpm_e2e_dspark}
NPRED=${1:-128}; ROUNDS=${2:-3}
COOLDOWN=${COOLDOWN:-90}
# 必须与 run_mesa_matrix.sh:37 逐字相同，否则与 §5.2 的 CPU 3.14 t/s 不可比
PROMPT=${PROMPT:-'请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}

LOAD=$(cut -d' ' -f1 /proc/loadavg)
if [ "${LOAD%.*}" -gt 2 ] 2>/dev/null; then echo "!! loadavg=$LOAD > 2，非安静态，拒绝出裁决数"; exit 3; fi
# 内存预检闸（G-805，2026-10-21）：io8 腿起跑 30s 后 K40 整机重启（tx/rx 计数器清零为证）。
# 在唯一裁决机上拿整机赌一次不值 —— 余量不足就等，不硬跑。参照 JNI 侧 [oom-guard] 的做法。
MEMA=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
MEMT=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
: ${MIN_MEM_MB:=2048}
if [ -n "$MEMA" ] && [ "$MEMA" -lt "$MIN_MEM_MB" ]; then
  echo "!! MemAvailable=${MEMA}MB < ${MIN_MEM_MB}MB（MemTotal=${MEMT}MB）：内存余量不足，拒绝开跑（G-805 教训）"
  exit 5
fi

STAMP=$(date +%H%M)
# OUT 必须可外部指定（续跑用），且指纹文件按时间戳分名 —— 否则重跑会把首跑的三元组证据冲掉（R2）
OUT=${OUT:-/data/local/tmp/g920_$STAMP}; mkdir -p $OUT
FPR=$OUT/fingerprint_$(date +%H%M%S).txt
cd "$RUN" || exit 1

# ---- 证据三元组：先落盘再开跑（无指纹的数不入档，见网格纪律 R2）----
{
  echo "#### G-920 cpubank npred=$NPRED rounds=$ROUNDS start=$(date -Iseconds)"
  echo "#### loadavg=$LOAD  temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
  echo "#### RUN=$RUN B=$B BIN=$BIN"
  echo "#### M=$M"; echo "#### E=$E"
  [ -f "$RUN/BUILD_INFO" ] && { echo "#### BUILD_INFO"; sed 's/^/#  /' "$RUN/BUILD_INFO"; }
  [ -f "$B/lib/libRusticlOpenCL.so" ] && echo "#### mesa_md5=$(md5sum $B/lib/libRusticlOpenCL.so | awk '{print $1}')"
} | tee "$FPR"

leg () { # $1=tag  $2..=env（全部相对 CPU 基线叠加）
  T=$1; shift
  # 断点续跑（G-805/R7）：设备中途重启后，用 OUT=<上次目录> 重跑即可跳过已完成腿，只补没跑完的。
  if [ -s $OUT/$T.out ] && grep -aq 'e2e\]\[METRIC' $OUT/$T.out 2>/dev/null; then
    echo "-- LEG $T 跳过（已有 METRIC，续跑模式） $(grep -aoE 'tok_s=[0-9.]+' $OUT/$T.out | tail -1)"
    return 0
  fi
  echo "-- LEG $T [$*] $(date +%H:%M:%S) load=$(cut -d' ' -f1 /proc/loadavg) temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
  # CPU 腿：LD_LIBRARY_PATH 不含 Mesa bundle + GGML_OPENCL_OFF=1（照 run_mesa_matrix.sh:96）
  env LD_LIBRARY_PATH=$RUN:$RUN/lib:/data/local/tmp \
      GGML_OPENCL_OFF=1 GGML_OPENCL_OPFLUSH=0 \
      LLAMA_MOE_IO_THREADS=1 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 \
      E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=${E2E_TEMP:-0.7} \
      GGML_E2E_PROMPT="$PROMPT" \
      E2E_TOKDUMP=$OUT/$T.tok \
      "$@" \
      timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 \
      > $OUT/$T.out 2> $OUT/$T.err
  RC=$?
  METRIC=$(grep -a 'e2e\]\[METRIC' $OUT/$T.out | tail -1 | grep -aoE 'gen=[0-9]+ wall_ms=[0-9]+ tok_s=[0-9.]+ load_ms=[0-9]+')
  # **提交证据**才是身份，不是"有没有打印过 ggml_opencl 字样"。
  # 教训（G-908）：沿用 run_mesa_matrix.sh 的 `grep -ac ggml_opencl` 作硬闸是错的 —— 实测 CPU 腿第一腿就
  # 命中 1 行 `ggml_opencl: GGML_OPENCL_OFF=1 -> CPU-only mode`，那是**关闭声明**，不是执行证据。
  # 反过来也危险：一条只打印不提交的 Mesa 腿能骗过 `opencl_lines>0`。闸必须能被证伪（网格 R3 / 反向对照）。
  SUBMIT=$(grep -acE 'KGSLSUBMIT|clFlush|QueueSubmit|clEnqueue' $OUT/$T.err)
  OCLN=$(grep -ac ggml_opencl $OUT/$T.err)
  echo "   rc=$RC $METRIC | cpu_gate[submits=$SUBMIT ggml_opencl_lines=$OCLN]"
  # CPU 腿的硬闸：必须**零提交**；有提交 = 这条腿挂上了 GPU，数作废
  [ "$SUBMIT" -gt 0 ] && echo "   !! CPU 身份闸失败：提交数=$SUBMIT > 0，本腿不作数"
  [ "$SUBMIT" -eq 0 ] && [ "$OCLN" -gt 0 ] && echo "   （ok：$OCLN 行 ggml_opencl 是关闭声明，提交数=0 已证真 CPU）"
  grep -aoE 'pread_wall=[0-9]+ms' $OUT/$T.err | tail -1 | sed 's/^/   /'
  sleep $COOLDOWN
}

R=1
while [ $R -le "$ROUNDS" ]; do
  echo "===== ROUND $R ====="
  leg io1_r$R
  leg io4_r$R   LLAMA_MOE_IO_THREADS=4
  leg io8_r$R   LLAMA_MOE_IO_THREADS=8
  leg io1w64_r$R LLAMA_MOE_DECODE_WINDOW=64 LLAMA_MOE_ROUTE_KEEP=1
  R=$((R+1))
done

echo "=== G920_CPUBANK_DONE dir=$OUT ==="
echo "读法：grep -a 'LEG\\|rc=' 取每腿 tok_s，按 tag 前缀跨轮求中位；"
echo "     先确认 cpu_gate 全为 0，再看 IO_THREADS 各档的极差 —— 极差>=20% 即备忘 §F 成立，"
echo "     此后任何 CPU bank 数必须写成 'CPU bank (IO=n, W=w, LA=l, <md5>, <loadavg>, <temp>)' 才许引用。"
