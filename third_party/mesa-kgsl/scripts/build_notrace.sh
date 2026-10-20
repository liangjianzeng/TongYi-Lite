#!/usr/bin/env bash
# [Mesa 线] 编 notrace（运行时 trace-off 的 LD_PRELOAD 垫片）到 aarch64-android。
# 用法：third_party/mesa-kgsl/scripts/build_notrace.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=$ROOT/third_party/mesa-kgsl/tools/build-android
SRC=$ROOT/third_party/mesa-kgsl/tools/notrace.c

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  for c in "$HOME/android-sdk/ndk/27.0.12077973" "$HOME/Android/Sdk/ndk/27.0.12077973" /opt/android-ndk; do
    [ -d "$c" ] && ANDROID_NDK_HOME=$c && break
  done
fi
[ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ] || { echo "找不到 NDK" >&2; exit 1; }
HOSTDIR=$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* 2>/dev/null | grep -m1 "$(uname -m | sed 's/aarch64/linux-aarch64/;s/x86_64/linux-x86_64/')")
CC="$HOSTDIR/bin/clang"; SYSROOT="$HOSTDIR/sysroot"
ABI=${ANDROID_ABI:-arm64-v8a}; PLAT=${ANDROID_PLATFORM:-android-28}
case "$ABI" in arm64-v8a) TRIPLE=aarch64;; armeabi-v7a) TRIPLE=armv7;; x86_64) TRIPLE=x86_64;; *) TRIPLE=$ABI;; esac
APILVL=${PLAT#android-}

mkdir -p "$OUT"
"$CC" --target=$TRIPLE-linux-android$APILVL -D__ANDROID_API__=$APILVL -D_GNU_SOURCE \
  --sysroot="$SYSROOT" -O3 -DNDEBUG -fPIC -shared -Wall -Wextra \
  -Wl,-soname,libnotrace.so -o "$OUT/libnotrace.so" "$SRC"
{ echo "tool=notrace"; echo "git=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)";
  echo "cc=$CC"; echo "flags=-O3 -DNDEBUG -shared"; echo "built=$(date -Iseconds)"; } > "$OUT/BUILD_INFO_notrace"
ls -l "$OUT/libnotrace.so"
echo "跑法：adb -s <serial> push $OUT/libnotrace.so /data/local/tmp/ && 在取数脚本 env 里加 LD_PRELOAD=/data/local/tmp/libnotrace.so"
echo "验收：日志尾必须出现 [notrace] swallowed>0；swallowed=0 说明覆盖没生效，任何结论都不许下"
