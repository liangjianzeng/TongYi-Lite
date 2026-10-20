#!/usr/bin/env bash
# [Mesa 线] 新设备一键就位：把测量体 + 驱动运行时 + 取数脚本推到 /data/local/tmp，然后跑一条冒烟腿。
#
# 为什么要有它：接管后设备集会变（830 战场 / K40(Adreno650) 代打 740 做调试机）。
# 每台新机手搓 adb 命令 = 上一轮"数字不可信"的起点；一切从脚本走。
#
# 用法：
#   third_party/mesa-kgsl/scripts/bootstrap_device.sh <serial> [--from <src_serial>] [--model-src <serial>]
#     --from       从另一台已就位设备把 mesa_bionic 运行时整包搬过来（跨机搬运用 tar over adb）
#     --model-src  从另一台设备搬 gguf + experts（模型 1.6G+，只在目标机缺文件时搬）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BUILD=$ROOT/_probe/moe_probe/build-android
SER=${1:?用法: bootstrap_device.sh <serial> [--from <src>] [--model-src <src>]}
SRC=""; MSRC=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --from) SRC=${2:?--from 需要 serial}; shift 2 ;;
    --model-src) MSRC=${2:?--model-src 需要 serial}; shift 2 ;;
    *) echo "未知参数 $1" >&2; exit 2 ;;
  esac
done

MD=/storage/emulated/0/TongYiLite/models
M=minicpm-v4.7-35b-a3b-les.gguf
E=minicpm-v4.7-35b-a3b-les.experts

echo "== 0) 设备在线检查 =="
adb devices | grep -q "^$SER[[:space:]]*device" || { echo "设备不在线或未授权：先 adb connect $SER 并在机上点允许 USB 调试" >&2; exit 1; }
adb -s "$SER" shell 'getprop ro.product.model; getprop ro.board.platform; ls -l /dev/kgsl-3d0 2>/dev/null || echo NO_KGSL; grep MemTotal /proc/meminfo'

echo "== 1) 目录 =="
adb -s "$SER" shell 'mkdir -p /data/local/tmp/mesa_run/lib'

echo "== 2) 测量体 =="
[ -x "$BUILD/minicpm_e2e" ] || { echo "缺 $BUILD/minicpm_e2e，先跑 build_probes_android.sh" >&2; exit 1; }
adb -s "$SER" push "$BUILD/minicpm_e2e" /data/local/tmp/mesa_run/ >/dev/null
adb -s "$SER" push "$BUILD/BUILD_INFO" /data/local/tmp/mesa_run/ >/dev/null
[ -f "$ROOT/_probe/oclstub_build/libopencl_stub.so" ] && adb -s "$SER" push "$ROOT/_probe/oclstub_build/libopencl_stub.so" /data/local/tmp/mesa_run/lib/ >/dev/null
for s in run_mesa_matrix.sh run_p2_scan.sh run_p2_accept.sh run_kgsl_probe.sh; do
  adb -s "$SER" push "$ROOT/third_party/mesa-kgsl/scripts/$s" /data/local/tmp/$s >/dev/null
done
adb -s "$SER" shell 'chmod 755 /data/local/tmp/mesa_run/minicpm_e2e /data/local/tmp/run_*.sh'
adb -s "$SER" shell 'cat /data/local/tmp/mesa_run/BUILD_INFO'

echo "== 3) Mesa 驱动运行时 =="
HAS=$(adb -s "$SER" shell 'ls /data/local/tmp/mesa_bionic/lib/libRusticlOpenCL.so 2>/dev/null | wc -l' | tr -d '\r')
if [ "$HAS" != "1" ]; then
  if [ -n "$SRC" ]; then
    echo "   目标机无 mesa_bionic，从 $SRC 搬运…"
    TMP=$(mktemp -d)/mesa_bionic.tgz
    adb -s "$SRC" exec-out 'tar -C /data/local/tmp -czf - mesa_bionic' > "$TMP"
    ls -l "$TMP"
    adb -s "$SER" push "$TMP" /data/local/tmp/mesa_bionic.tgz >/dev/null
    adb -s "$SER" shell 'cd /data/local/tmp && rm -rf mesa_bionic && tar -xzf mesa_bionic.tgz && rm mesa_bionic.tgz'
  else
    echo "   !! 目标机没有 /data/local/tmp/mesa_bionic，且没给 --from <已就位设备>。" >&2
    echo "      没有驱动体就只能跑 CPU 腿，Mesa 腿一律不许取数。" >&2
  fi
fi
adb -s "$SER" shell 'ls -l /data/local/tmp/mesa_bionic/lib/libRusticlOpenCL.so 2>/dev/null | wc -l; ls /data/local/tmp/mesa_bionic/lib 2>/dev/null | head -8; ls /data/local/tmp/mesa_bionic/lib/clang/21/include 2>/dev/null | head -3'

echo "== 4) 模型文件 =="
for f in "$M" "$E"; do
  C=$(adb -s "$SER" shell "[ -e $MD/$f ] && echo Y || echo N" | tr -d '\r')
  if [ "$C" != "Y" ]; then
    if [ -n "$MSRC" ]; then
      echo "   $f 缺失，从 $MSRC 搬运（大文件，慢）…"
      adb -s "$MSRC" exec-out "cat $MD/$f" > /tmp/$(basename "$f")
      adb -s "$SER" push /tmp/$(basename "$f") "$MD/$f" >/dev/null
    else
      echo "   !! 缺 $MD/$f（用 --model-src <serial> 从已有设备搬）" >&2
    fi
  fi
done
adb -s "$SER" shell "ls -l $MD/$M $MD/$E 2>/dev/null"

echo "== 5) 冒烟：CPU 腿 8 token（只证明测量体在这台机能跑，不取 Mesa 数）=="
adb -s "$SER" shell 'cd /data/local/tmp/mesa_run && LD_LIBRARY_PATH=/data/local/tmp/mesa_run/lib:/data/local/tmp GGML_OPENCL_OFF=1 E2E_NBATCH=512 E2E_SEED=42 E2E_TEMP=0 timeout 300 ./minicpm_e2e '"$MD/$M"' '"$MD/$E"' 0 8 512 2>/dev/null | tail -c 220; echo'

echo "== 6) 冒烟：Mesa 腿 8 token（有驱动体才跑；这条只验能不能起来，正确性看 run_p2_accept.sh）=="
if [ "$(adb -s "$SER" shell 'ls /data/local/tmp/mesa_bionic/lib/libRusticlOpenCL.so 2>/dev/null | wc -l' | tr -d '\r')" = "1" ]; then
  adb -s "$SER" shell 'cd /data/local/tmp/mesa_run && LD_LIBRARY_PATH=/data/local/tmp/mesa_run/lib:/data/local/tmp/mesa_bionic/lib:/data/local/tmp OCL_ICD_VENDORS=/data/local/tmp/mesa_bionic/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl HOME=/data/local/tmp/mesa_bionic/tmp XDG_CACHE_HOME=/data/local/tmp/mesa_bionic/tmp CLC_RESOURCE_DIR=/data/local/tmp/mesa_bionic/lib/clang/21/include GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1 GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_OPFLUSH=1 E2E_NBATCH=512 E2E_SEED=42 E2E_TEMP=0 timeout 420 ./minicpm_e2e '"$MD/$M"' '"$MD/$E"' 0 8 512 2>/dev/null | tail -c 220; echo'
else
  echo "   跳过（无驱动体）"
fi
echo "=== BOOTSTRAP_DONE $SER ==="
