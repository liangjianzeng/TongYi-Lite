#!/usr/bin/env bash
# vkh_r121_件_arch_审计.sh —— 件的指令级 arch 审计（父 740 SIGILL 案 / 构建旗标对照表）
# 作者 vkh 2026-10-28｜宿主侧枪，不碰设备｜用途：任何一手 libggml-cpu*（单架构或 ALL_VARIANTS 多架构）
# 一条命令回答："这手件到底能不能在目标机上跑"——**不看 -march 猜，直接数指令**。
#
# 为什么必须指令级（血案榜）：
#   · AGENTS.md 判例：Cortex-A78(ARMv8.2) 无 i8mm，GGML_CPU_ARM_ARCH 写 armv8.4+dotprod+i8mm
#     ⇒ 共享 CPU 加载/repack 路 SIGILL ⇒ "三个后端全崩"（与后端无关，最易误诊）。
#   · 本枪新案（2026-10-28 740）：若件在 **DGX 宿主（Neoverse V2 / armv9.2-a + SVE2 + SME2）**
#     用 GGML_NATIVE 默认 ON 编出，就会把宿主独有指令烘进件里 ⇒ 手机 SIGILL(132)，
#     而 ling 全 GPU（零 CPU 岛）不碰 ggml-cpu 内核 ⇒ "同 stack ling 健康 LFM 死"。
#
# 出厂自检（哑火 #26 族规）：先验 objdump 存在，缺则 ABORT 不出结论。
set -u
command -v objdump >/dev/null 2>&1 || { echo "#### VAUDIT_ABORT reason=no_objdump"; exit 2; }
[ $# -ge 1 ] || { echo "用法: $0 <文件或目录> [更多...]  (目录会扫 libggml-cpu*)"; echo "  可选环境变量 CPUIINFO=<file> 贴设备 /proc/cpuinfo 以判变体选择"; exit 2; }

# 目标机能力（可选，用于变体选择判定）
FEAT=""
if [ -n "${CPUIINFO:-}" ] && [ -f "$CPUIINFO" ]; then
  FEAT=$(grep -m1 -i "^Features" "$CPUIINFO" | tr 'A-Z' 'a-z')
  echo "#### VAUDIT_CPUINFO features=${FEAT:0:220}"
fi

census() {  # $1=文件 $2=标签
  local f=$1 tag=$2 tmp=/tmp/vkh_obj_$$.txt
  [ -f "$f" ] || { echo "  -- $tag : 缺文件 $f"; return; }
  if ! objdump -d --no-show-raw-insn "$f" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    echo "  -- $tag : objdump 失败（非 ELF 或已 strip？）"; return
  fi
  local n sve ptrue i8 dp bf sme fp16
  n=$(wc -l < "$tmp")
  sve=$(grep -cE "\bz[0-9]+\b" "$tmp" || true)
  ptrue=$(grep -cE "\b(ptrue|pfalse|whilelo|ld1b|ldff1b|index)\b" "$tmp" || true)
  sme=$(grep -cE "\b(sm(tidwh|stop|allocate|writeza|zero)|za[0-9])\b" "$tmp" || true)
  i8=$(grep -cE "\b(smmla|usmla|smmls)\b" "$tmp" || true)
  dp=$(grep -cE "\b(udot|sdot)\b" "$tmp" || true)
  bf=$(grep -c "dpbf16" "$tmp" || true)
  fp16=$(grep -cE "fmla\.[0-9]+h" "$tmp" || true)
  printf "  -- %-46s insns=%-8s SVE(z)=%-6s SVE-ctrl=%-6s SME=%-5s i8mm=%-5s dotprod=%-6s bf16=%-5s fp16vec=%s\n" \
         "$tag" "$n" "$sve" "$ptrue" "$sme" "$i8" "$dp" "$bf" "$fp16"
  # 判语（对最低档 K40 = Cortex-A77/ARMv8.2：无 SVE 无 SME 无 i8mm）
  local v="K40(A77)可跑"
  [ "$sve" -gt 0 ] || [ "$ptrue" -gt 0 ] && v="K40 必 SIGILL(SVE)"
  [ "$sme" -gt 0 ] && v="K40/740 皆险(SME=宿主独有)"
  [ "$i8" -gt 0 ] && v="$v; A77 无 i8mm 路需运行时分派"
  echo "     判语: $v"
  rm -f "$tmp"
}

for tgt in "$@"; do
  echo "#### VAUDIT_TARGET $tgt"
  if [ -d "$tgt" ]; then
    ls "$tgt"/libggml-cpu*.so* 2>/dev/null | while read -r f; do census "$f" "$(basename "$f")"; done
    ls "$tgt"/libggml-cpu.so* 2>/dev/null | grep -q . || echo "  (目录内无 libggml-cpu*：非 CPU 后端件目录？)"
  else
    census "$tgt" "$(basename "$tgt")"
  fi
done

# 已知良好参照（本仓实测，2026-10-28）：
#   _probe/vkh_830/lfm_kit2/libggml-cpu.so.0 : SVE=0 SME=0 i8mm=0 dotprod=1168
#   （= armv8.2-a+dotprod，在 K40/Adreno650 上真机跑出过 LFM CPU 1.41 t/s = 金标件）
echo "#### VAUDIT_DONE"
