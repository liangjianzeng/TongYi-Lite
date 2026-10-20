#!/usr/bin/env bash
# [Mesa 线] 编 trace_tax（trace 打印税量上界尺子）到 aarch64-android。
# 与 build_probes_android.sh 同一把 NDK 口径（裸 clang 必须显式挂 sysroot，否则吃宿主 glibc）。
#
# 用法：third_party/mesa-kgsl/scripts/build_trace_tax.sh [--clean]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=$ROOT/third_party/mesa-kgsl/tools/build-android
SRC=$ROOT/third_party/mesa-kgsl/tools/trace_tax.c

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

[ "${1:-}" = "--clean" ] && rm -rf "$OUT"
mkdir -p "$OUT"
echo "[trace_tax] CC=$CC"
"$CC" --target=$TRIPLE-linux-android$APILVL -D__ANDROID_API__=$APILVL -D_GNU_SOURCE \
  --sysroot="$SYSROOT" -O3 -DNDEBUG -fno-omit-frame-pointer -Wall -Wextra \
  -o "$OUT/trace_tax" "$SRC"
{ echo "tool=trace_tax"; echo "git=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)";
  echo "cc=$CC"; echo "flags=-O3 -DNDEBUG"; echo "built=$(date -Iseconds)"; } > "$OUT/BUILD_INFO"
ls -l "$OUT/trace_tax"; cat "$OUT/BUILD_INFO"
echo "跑法：adb -s <serial> push $OUT/trace_tax /data/local/tmp/ && adb -s <serial> shell '/data/local/tmp/trace_tax 64 3 >/dev/null 2>/dev/null'"
