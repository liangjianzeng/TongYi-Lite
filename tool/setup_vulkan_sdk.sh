#!/usr/bin/env bash
# TongYi-Lite —— Linux 打包机构建 ggml-vulkan 所需 Vulkan SDK 的组装脚本
#
# 背景：LunarG 官方不发 linux-aarch64 的 Vulkan SDK 压缩包（packages.lunarg.com /
# sdk.lunarg.com 均 404），而 CMakeLists（android/app/src/main/cpp）期望一个
# LunarG 布局的 SDK 目录：
#     $SDK/Bin/glslc[.exe]                      SPIR-V 编译器
#     $SDK/Include/vulkan/vulkan.hpp             C++ 绑定（NDK sysroot 没有）
#     $SDK/Include/spirv/...                     SPIRV-Headers
#     $SDK/Lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake
# Windows 打包机直接装官方 .exe 安装器即可；Linux（尤其 aarch64）用本脚本从
# 发行版原生 deb 组装出同布局目录，glslc 是 **原生 arm64**（不需要 FEX）。
#
# 用法：
#   tool/setup_vulkan_sdk.sh            # 组装到 ~/vulkan-sdk（幂等）
#   VULKAN_SDK_DIR=/opt/vulkan-sdk tool/setup_vulkan_sdk.sh
#
# 组装完成后 CMake 会自动发现（cpp/CMakeLists.txt 宿主分派：Linux 默认
# ~/vulkan-sdk，可用 VULKAN_SDK 环境变量覆盖），无需其他配置。
#
# 支持发行版：Ubuntu/Debian（dpkg 解包，无需 root/sudo）。
set -euo pipefail

SDK_DIR="${VULKAN_SDK_DIR:-$HOME/vulkan-sdk}"
PKGS=(glslc libvulkan-dev spirv-headers libshaderc1)

echo "== 组装 Vulkan SDK → $SDK_DIR （$(dpkg --print-architecture) 原生）"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$SDK_DIR/Bin" "$SDK_DIR/Include" "$SDK_DIR/Lib"

cd "$TMP"
for p in "${PKGS[@]}"; do
  if ! apt-get download "$p" >/dev/null 2>&1; then
    echo "  ✗ apt-get download $p 失败（确认源可用；或手动放置 .deb 于 $TMP）" >&2
    exit 1
  fi
  dpkg-deb -x "${p}_"*/ "x_$p" 2>/dev/null || dpkg-deb -x "$(ls -t ${p}_*.deb | head -1)" "x_$p"
done

# glslc 真身 + 运行库（libshaderc.so.1），外面包一层 wrapper 注入 LD_LIBRARY_PATH
install -m 755 x_glslc/usr/bin/glslc "$SDK_DIR/Bin/glslc.bin"
find x_libshaderc1 -name 'libshaderc.so*' -exec cp -P {} "$SDK_DIR/Lib/" \;
cat > "$SDK_DIR/Bin/glslc" <<'WRAP'
#!/bin/sh
# 见文件头：deb 版 glslc 依赖 libshaderc.so.1，从同 SDK 的 Lib/ 找。
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LD_LIBRARY_PATH="$d/../Lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$d/glslc.bin" "$@"
WRAP
chmod 755 "$SDK_DIR/Bin/glslc"

# vulkan.hpp（ggml-vulkan.cpp 需要）+ spirv headers + cmake config
cp -r x_libvulkan-dev/usr/include/vulkan "$SDK_DIR/Include/"
cp -r x_spirv-headers/usr/include/spirv   "$SDK_DIR/Include/"
cp -r x_spirv-headers/usr/share/cmake/SPIRV-Headers "$SDK_DIR/Lib/cmake/"

# vk_video/ 编解码头：Vulkan 1.4 的 vulkan_core.h 会 #include "vk_video/..."，
# 发行版没有独立 deb，从 KhronosGroup/Vulkan-Headers 官方仓库取对应版本。
# （SDK 布局：vk_video 与 vulkan 平级 —— -I$SDK/Include 下两个 include 都命中）
if [[ ! -d "$SDK_DIR/Include/vk_video" ]]; then
  HV=$(grep -oP 'define VK_HEADER_VERSION \K[0-9]+' "$SDK_DIR/Include/vulkan/vulkan_core.h" || echo "")
  if [[ -n "$HV" ]]; then
    tmp2="$(mktemp -d)"
    if curl -fsSL --retry 2 -o "$tmp2/vh.tgz" \
        "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.$HV.tar.gz" \
       && tar xzf "$tmp2/vh.tgz" -C "$tmp2" \
       && [[ -d "$tmp2/Vulkan-Headers-1.4.$HV/include/vk_video" ]]; then
      cp -r "$tmp2/Vulkan-Headers-1.4.$HV/include/vk_video" "$SDK_DIR/Include/"
      echo "  ✓ Include/vk_video（Vulkan-Headers v1.4.$HV）"
    else
      echo "  ! vk_video 头获取失败（v1.4.$HV）：手动从 KhronosGroup/Vulkan-Headers 拷 include/vk_video 到 Include/" >&2
    fi
    rm -rf "$tmp2"
  fi
fi

# 自检（与 cpp/CMakeLists.txt 的判定一一对应）
fail=0
[[ -x "$SDK_DIR/Bin/glslc" ]] && "$SDK_DIR/Bin/glslc" --version >/dev/null && echo "  ✓ glslc 可执行（$("$SDK_DIR/Bin/glslc" --version 2>/dev/null | head -1)）" || { echo "  ✗ glslc 跑不起来"; fail=1; }
[[ -f "$SDK_DIR/Include/vulkan/vulkan.hpp" ]] && echo "  ✓ Include/vulkan/vulkan.hpp" || { echo "  ✗ 缺 vulkan.hpp"; fail=1; }
[[ -f "$SDK_DIR/Lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" ]] && echo "  ✓ SPIRV-HeadersConfig.cmake" || { echo "  ✗ 缺 SPIRV-HeadersConfig"; fail=1; }

[[ $fail == 0 ]] || { echo "组装未完成。" >&2; exit 1; }
echo "== 完成。下次 tool/build_apk.sh 构建将自动启用 Vulkan 后端（configure 摘要见 \"Vulkan ENABLED\"）。"
