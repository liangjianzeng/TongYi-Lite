#!/usr/bin/env bash
# run_cl_cc_probe.sh —— 跑 G-734 的 Adreno/Mesa **编译门**探针（不动 third_party/llama.cpp 一行）
#
# 一次实验出四格结论（两栈 × 两载荷），且带阳性对照，所以它自己也会被判真伪：
#   vendor Adreno  × probe_ctrl_half.cl  ⇒ 期望 COMPILE_FAIL（AGENTS 已知 half 故障）
#   vendor Adreno  × probe_iq4xs_min.cl  ⇒ 本轮要的答案
#   Mesa rusticl   × probe_ctrl_half.cl  ⇒ 期望 COMPILE_OK（那边 half 是合法标识符）
#   Mesa rusticl   × probe_iq4xs_min.cl  ⇒ 本轮要的答案
# 对照腿若不符合期望 ⇒ 探针无效，本轮所有编译门结论作废（R8：永远不会失败的闸不算闸）。
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)   # REPO=TongYi-Lite/third_party
REPO=$(cd "$REPO/.." && pwd)                                            # → 仓库根 TongYi-Lite/
DEV=${DEV:-100.67.150.120:5555}
NDK=${NDK:-$HOME/android-sdk/ndk/27.0.12077973}
CC="$NDK/toolchains/llvm/prebuilt/$(uname -m | sed 's/aarch64/linux-aarch64/;s/x86_64/linux-x86_64/')/bin/clang"
SYS="$NDK/toolchains/llvm/prebuilt/$(uname -m | sed 's/aarch64/linux-aarch64/;s/x86_64/linux-x86_64/')/sysroot"
B=${B:-/data/local/tmp/mesa_bionic}            # 我们自研 Mesa 束（与 run_mesa_matrix.sh 同源）
OUT=$HERE/../build/cl_cc_probe
mkdir -p "$HERE/../build"

echo "== 1/4 交叉编译探针 =="
[ -x "$CC" ] || { echo "!! NDK clang 不在：$CC（NDK= 可覆盖）" >&2; exit 2; }
"$CC" --target=aarch64-linux-android29 --sysroot="$SYS" -O1 -Wall -DCL_TARGET_OPENCL_VERSION=300 \
      -I"$REPO/third_party/OpenCL-Headers" -o "$OUT" "$HERE/../tools/cl_cc_probe.c" -ldl || exit 2
ls -la "$OUT"

echo "== 2/4 推送 =="
adb -s "$DEV" push "$OUT" /data/local/tmp/cl_cc_probe >/dev/null
for f in "$HERE"/../tools/probe_payloads/*.cl; do adb -s "$DEV" push "$f" /data/local/tmp/ >/dev/null; done
adb -s "$DEV" shell 'chmod 755 /data/local/tmp/cl_cc_probe'

run_leg() {  # $1=栈名 $2=PROBE_OCL $3=.cl(可空) $4=期望
  local tag=$1 ocl=$2 cl=$3 want=$4 env_extra=""
  [ -n "${FORCE_OCL:-}" ] && ocl="$FORCE_OCL"
  if [ "$tag" = "mesa" ]; then
    env_extra="LD_LIBRARY_PATH=$B/lib:/data/local/tmp OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl HOME=/data/local/tmp XDG_CACHE_HOME=/data/local/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include"
  else
    env_extra="LD_LIBRARY_PATH=/vendor/lib64:/system/lib64:/data/local/tmp"
  fi
  echo "---- leg=$tag ocl=$ocl src=${cl:-<能力清单>} 期望=${want:-—} ----"
  adb -s "$DEV" shell "PROBE_OCL='$ocl' $env_extra /data/local/tmp/cl_cc_probe ${cl:+/data/local/tmp/$cl} >/data/local/tmp/cc_probe.out 2>&1; echo "[\$tag] RC=\$\$?"; sed -e 's/^/[$tag] /' /data/local/tmp/cc_probe.out"
  echo "---- leg=$tag 完 ----"
}

echo; if [ "${CAPONLY:-0}" = "1" ]; then
  echo "== 仅能力清单 =="
  run_leg vendor /vendor/lib64/libOpenCL.so "" "-"
  run_leg mesa   "${MESAOCL:-$B/lib/libOpenCL.so}" "" "-"
  exit 0
fi
echo "== 3/4 能力清单（dp4a 的真相在这，不在内核的 #ifdef 里）=="
run_leg vendor /vendor/lib64/libOpenCL.so "" "—"
run_leg mesa   "${MESAOCL:-$B/lib/libOpenCL.so}" "" "—"

echo; echo "== 4/4 编译门（阳性对照 + 被测最小 IQ4_XS dequant）=="
run_leg vendor /vendor/lib64/libOpenCL.so probe_ctrl_half.cl "COMPILE_FAIL(AGENTS 已知)"
run_leg mesa   "${MESAOCL:-$B/lib/libOpenCL.so}" probe_ctrl_half.cl "COMPILE_OK(half 在那边合法)"
run_leg vendor /vendor/lib64/libOpenCL.so probe_iq4xs_min.cl "COMPILE_OK"
run_leg mesa   "${MESAOCL:-$B/lib/libOpenCL.so}" probe_iq4xs_min.cl "COMPILE_OK"
