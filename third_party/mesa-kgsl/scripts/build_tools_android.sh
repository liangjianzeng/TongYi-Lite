#!/usr/bin/env bash
# [Mesa 线] 把 third_party/mesa-kgsl/tools/*.c 里的独立量具编到 aarch64-android。
# 与 build_probes_android.sh 同一把 NDK 口径（裸 clang 必须显式挂 sysroot，否则吃宿主 glibc）。
# 取代早期"一个量具一个 build_*.sh"的复制粘贴。
#
# 用法：build_tools_android.sh [tool ...]        # 不给参数 = tools/ 下全部 .c
#       ANDROID_ABI=arm64-v8a ANDROID_PLATFORM=android-28 build_tools_android.sh kgsl_props
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TOOLS=$ROOT/third_party/mesa-kgsl/tools
OUT=$TOOLS/build-android

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  for c in "$HOME/android-sdk/ndk/27.0.12077973" "$HOME/Android/Sdk/ndk/27.0.12077973" /opt/android-ndk; do
    [ -d "$c" ] && ANDROID_NDK_HOME=$c && break
  done
fi
[ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ] || {
  echo "找不到 NDK：设 ANDROID_NDK_HOME" >&2; exit 1; }
HOSTDIR=$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* 2>/dev/null | grep -m1 "$(uname -m | sed 's/aarch64/linux-aarch64/;s/x86_64/linux-x86_64/')")
CC="$HOSTDIR/bin/clang"; SYSROOT="$HOSTDIR/sysroot"
ABI=${ANDROID_ABI:-arm64-v8a}; PLAT=${ANDROID_PLATFORM:-android-28}
# ANDROID_ABI 是 gradle 口径（arm64-v8a），clang 的 triple 要 aarch64；PLAT 要剥掉 "android-" 前缀
case "$ABI" in arm64-v8a) TRIPLE=aarch64;; armeabi-v7a) TRIPLE=armv7;; x86_64) TRIPLE=x86_64;; *) TRIPLE=$ABI;; esac
APILVL=${PLAT#android-}

mkdir -p "$OUT"
NAMES=${*:-$(cd "$TOOLS" && ls *.c 2>/dev/null | sed 's/\.c$//')}
BUILT=""
for n in $NAMES; do
  src=$TOOLS/$n.c
  [ -f "$src" ] || { echo "   !! 没有 $src，跳过" >&2; continue; }
  extra=""
  case "$n" in *_shm) extra="-lpthread";; esac
  echo "[$n] CC=$CC"
  "$CC" --target=$TRIPLE-linux-android$APILVL -D__ANDROID_API__=$APILVL -D_GNU_SOURCE \
    -DCL_TARGET_OPENCL_VERSION=310 -I"$ROOT/third_party/OpenCL-Headers" \
    --sysroot="$SYSROOT" -O3 -DNDEBUG -fno-omit-frame-pointer -Wall -Wextra \
    -o "$OUT/$n" "$src" $extra
  BUILT="$BUILT $n"
done
{ echo "git=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)";
  echo "cc=$CC"; echo "abi=$ABI platform=$PLAT flags=-O3 -DNDEBUG";
  echo "built=$(date -Iseconds)"; echo "tools=$BUILT"; } > "$OUT/BUILD_INFO"
ls -l $OUT $(echo $BUILT | tr ' ' '\n' | sed 's|^|-o |' | tr '\n' ' ') 2>/dev/null | tail -n +2
cat "$OUT/BUILD_INFO"
echo "推送：adb -s <serial> push $OUT/<tool> /data/local/tmp/ && adb -s <serial> shell /data/local/tmp/<tool>"
