#!/usr/bin/env bash
# vkh_imagecap_build.sh — 镜像能力探针的宿主构建枪（R-117）
#   与腿同栈：产物必须是 **glibc aarch64**（腿跑在 CLRT sysroot + glibc loader 下），
#   不是 Android bionic、不是 NDK。常数唯一来源 = 树内 vendored Khronos 头（与产品库同源）。
#   父跑（vkh 无 chroot sudo）：bash vkh_imagecap_build.sh
#   可用覆盖：CC=<交叉cc> CHROOT=<前缀> REPO=<repo> STATIC=0
set -euo pipefail
REPO=${REPO:-/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite}
SRC=$REPO/_probe/vkh_830/vkh_imagecap.c
HDR=$REPO/third_party/OpenCL-Headers
OUT=${OUT:-$REPO/_probe/vkh_830/dist}
CC=${CC:-aarch64-linux-gnu-gcc}
[ -n "${CHROOT:-}" ] && CC="$CHROOT/$CC"   # 例：CHROOT=/root/routeA/sandbox
STATIC=${STATIC:-1}
mkdir -p "$OUT"
[ -f "$SRC" ] || { echo "#### IC_BUILD_ABORT no_src"; exit 1; }
[ -f "$HDR/CL/cl.h" ] || { echo "#### IC_BUILD_ABORT no_cl_headers dir=$HDR"; exit 1; }
command -v "$CC" >/dev/null 2>&1 || [ -x "$CC" ] || { echo "#### IC_BUILD_ABORT no_cc cc=$CC"; exit 1; }

ST=(); [ "$STATIC" = "1" ] && ST=(-static)
echo "#### IC_BUILD start cc=$CC static=$STATIC hdr=$HDR"
if ! "$CC" -O2 -Wall -Wextra -Werror=int-conversion -I"$HDR" "${ST[@]}" -o "$OUT/vkh_imagecap" "$SRC" -ldl 2>"$OUT/build.log"; then
  if [ "$STATIC" = "1" ]; then
    echo "#### IC_BUILD_NOTE static_failed → retry dynamic（glibc 静态库缺失，腿侧务必带 LOADER/LP）"
    "$CC" -O2 -Wall -Wextra -Werror=int-conversion -I"$HDR" -o "$OUT/vkh_imagecap" "$SRC" -ldl 2>"$OUT/build.log"
    STATIC=0
  else
    echo "#### IC_BUILD_ABORT compile_failed"; tail -25 "$OUT/build.log"; exit 1
  fi
fi
file "$OUT/vkh_imagecap" 2>/dev/null | head -1
# 红牌：必须 ELF ARM aarch64，且不得是 bionic/NDK 产物
file "$OUT/vkh_imagecap" | grep -q "ARM aarch64" || { echo "#### IC_BUILD_ABORT not_aarch64"; exit 1; }
"$CC" --version 2>/dev/null | head -1 | sed 's/^/#### IC_BUILD toolchain=/'
md5sum "$OUT/vkh_imagecap" | awk '{print "#### IC_BUILD_ARTIFACT md5="$1" bytes='"$(stat -c%s "$OUT/vkh_imagecap")"' static='"$STATIC"'}'
echo "#### IC_BUILD_DONE out=$OUT/vkh_imagecap"
