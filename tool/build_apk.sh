#!/usr/bin/env bash
# TongYi-Lite —— Linux 打包机（含 aarch64/DGX Spark）一键 APK 构建
#
# 结构与 tool/build_apk.sh（DSH-Phone 同构，先读那边的四个 aarch64 大坑注释）：
#   环境自检 → （可选）artifacts 修复 → flutter 构建 → 签名验收。
# 本项目在其之上追加：
#   A) NDK/llama.cpp 编译链检查（clang 可执行、ndk host 目录、CMake）
#   B) Vulkan 后端开关自检（tool/setup_vulkan_sdk.sh 组装的 SDK 目录）
#   C) gradlew 执行位 + gradle-wrapper.jar 自愈（历史 .gitignore 坑，见 docs/BUILD-linux.md）
#   D) release 产物 apksigner 签名验收（必须 CN=TongYiLite / 指纹匹配，AGENTS 铁律）
#   E) 默认 debug+release 一起打（AGENTS 默认打包策略），--release/--debug 单选
#   F) ninja/gradle 并行度按 MemAvailable 自适应（vLLM 常驻机上防 OOM）
#
# 用法：
#   tool/build_apk.sh                 # debug + release 都打（默认）
#   tool/build_apk.sh --release       # 只 release   tool/build_apk.sh --debug 只 debug
#   tool/build_apk.sh --check         # 只环境自检
#   tool/build_apk.sh --fix-artifacts # 补 flutter arm64 主机 gen_snapshot（需联网，幂等）
#   tool/build_apk.sh --clean-native  # 清 .cxx 全量重编 NDK（改了 native/cpp 必须用它，
#                                     #   防 AGENTS 记录的 "NDK up-to-date 跳过致 .so 陈旧"）
#   tool/build_apk.sh --install       # 成功后 adb install -r（绝不卸载，AGENTS 铁律）
#                                     #   多设备时必须 DEVICE=<ip:5555> 指定，否则报错退出
#   tool/build_apk.sh --analyze       # 构建前 flutter analyze
# 环境变量覆盖：FLUTTER_BIN / ANDROID_HOME / JAVA_HOME / VULKAN_SDK
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODES=(debug release)
TARGET_PLATFORM=android-arm64
RUN_ANALYZE=0; RUN_CHECK_ONLY=0; FIX_ARTIFACTS=0; RUN_INSTALL=0; CLEAN_NATIVE=0

for arg in "$@"; do
  case "$arg" in
    --release) MODES=(release) ;;
    --debug)   MODES=(debug) ;;
    --all-abi) TARGET_PLATFORM= ;;
    --analyze) RUN_ANALYZE=1 ;;
    --check)   RUN_CHECK_ONLY=1 ;;
    --fix-artifacts) FIX_ARTIFACTS=1 ;;
    --clean-native) CLEAN_NATIVE=1 ;;
    --install) RUN_INSTALL=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$arg（--help 看用法）" >&2; exit 2 ;;
  esac
done

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }

# ---------------------------------------------------------------- 组件定位
FLUTTER="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER" ]]; then
  for c in "$(command -v flutter || true)" "$HOME/flutter/bin/flutter" /opt/flutter/bin/flutter; do
    [[ -n "$c" && -x "$c" ]] && { FLUTTER="$c"; break; }
  done
fi
[[ -n "$FLUTTER" ]] || { echo "找不到 flutter（设 FLUTTER_BIN 或加入 PATH）" >&2; exit 1; }
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER")/.." && pwd)"

pick_sdk() {
  for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/android-sdk" \
           /opt/android-sdk /usr/lib/android-sdk; do
    [[ -n "$c" && -d "$c/platforms" && -d "$c/build-tools" ]] && { echo "$c"; return; }
  done
  echo ""
}
ANDROID_SDK="$(pick_sdk)"

pick_jdk17() {
  local arch; arch="$(uname -m)"
  for c in "${JAVA_HOME:-}" "/usr/lib/jvm/java-17-openjdk-${arch}" \
           /usr/lib/jvm/java-17-openjdk-arm64 /usr/lib/jvm/temurin-17-jdk-${arch} \
           /usr/lib/jvm/openjdk-17; do
    [[ -n "$c" && -x "$c/bin/java" ]] && { echo "$c"; return; }
  done
  echo ""
}
JAVA17="$(pick_jdk17)"

STORAGE_BASE="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
ENGINE="$(tr -d '[:space:]' < "$FLUTTER_ROOT/bin/internal/engine.version" || true)"
ENG_DIR="$FLUTTER_ROOT/bin/cache/artifacts/engine"

# ---------------------------------------------------------------- 环境自检
echo "== 环境自检（$(uname -srm)）"
ok "flutter  $FLUTTER"
ver="$("$FLUTTER" --version 2>&1 | head -1 || true)"
[[ "$ver" == Flutter* ]] && ok "$ver" || bad "flutter 无法执行：$ver"

if [[ -n "$ANDROID_SDK" ]]; then
  ok "Android SDK  $ANDROID_SDK"
  cs=$(sed -n 's/.*compileSdk *= *\([0-9]\+\).*/\1/p' "$PROJ_ROOT/android/app/build.gradle.kts" 2>/dev/null | head -1)
  [[ -z "$cs" ]] && cs=$(sed -n 's/.*compileSdk *= *\([0-9]\+\).*/\1/p' "$PROJ_ROOT/android/app/build.gradle" 2>/dev/null | head -1)
  if [[ -n "$cs" && -d "$ANDROID_SDK/platforms/android-$cs" ]]; then
    ok "platforms/android-$cs"
  elif [[ -n "$cs" ]]; then
    bad "缺 platforms/android-$cs：\$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager \"platforms;android-$cs\""
  fi
  ls "$ANDROID_SDK"/build-tools/*/aapt2 >/dev/null 2>&1 && ok "build-tools $(ls "$ANDROID_SDK/build-tools" | tr '\n' ' ')" || bad "缺 build-tools（含 aapt2）"

  # local.properties 防 flutter 覆写回 apt SDK（/usr/lib/android-sdk 无 platforms，
  # 症状：LicenceNotAcceptedException / 找不到 compileSdk）。每次构建前自愈。
  lp="$PROJ_ROOT/android/local.properties"; want="sdk.dir=$ANDROID_SDK"
  if [[ -f "$lp" ]]; then
    cur=$(sed -n 's/^sdk.dir=//p' "$lp" | head -1)
    if [[ "$cur" != "$ANDROID_SDK" ]]; then
      if grep -q '^sdk.dir=' "$lp"; then sed -i "s|^sdk.dir=.*|$want|" "$lp"; else printf '%s\n' "$want" >> "$lp"; fi
      warn "local.properties sdk.dir=$cur → 已修正为 $ANDROID_SDK"
      "$FLUTTER" config --android-sdk "$ANDROID_SDK" >/dev/null 2>&1 || true
    else
      ok "local.properties sdk.dir 正确"
    fi
  else
    printf '%s\nflutter.sdk=%s\n' "$want" "$FLUTTER_ROOT" > "$lp"
    warn "已生成 android/local.properties"
  fi
else
  bad "找不到含 platforms+build-tools 的 Android SDK（设 ANDROID_HOME）"
fi

[[ -n "$JAVA17" ]] && ok "JDK 17  $JAVA17" || bad "找不到 JDK 17（AGP 要求；apt install openjdk-17-jdk）"

# 机器层 gradle 配置（java.home/jvmargs/workers）：项目层已去机器化，缺了会退回默认堆
if [[ -f "$HOME/.gradle/gradle.properties" ]] && grep -q 'org.gradle.java.home' "$HOME/.gradle/gradle.properties"; then
  ok "机器层 ~/.gradle/gradle.properties（java.home 已配）"
else
  warn "缺 ~/.gradle/gradle.properties 机器层（建议配 org.gradle.java.home/jvmargs/workers，见 docs/BUILD-linux.md）"
fi

# gradlew / wrapper jar 自愈（历史 .gitignore 坑）
ga="$PROJ_ROOT/android/gradlew"
[[ -x "$ga" ]] || { chmod +x "$ga" && warn "gradlew 执行位已补（git update-index --chmod=+x 待提交）"; }
[[ -f "$PROJ_ROOT/android/gradle/wrapper/gradle-wrapper.jar" ]] \
  && ok "gradle-wrapper.jar 就位" \
  || bad "缺 android/gradle/wrapper/gradle-wrapper.jar：cd android && <gradle-8.9> wrapper --gradle-version 8.9 --distribution-type all 重生成后必须提交"

# amd64 运行库 / FEX / gen_snapshot（详见 DSH-Phone tool/build_apk.sh 头注释 2)3)4)）
[[ -e /lib64/ld-linux-x86-64.so.2 ]] && ok "amd64 运行库就位" || bad "缺 amd64 运行库（dpkg --add-architecture amd64 + libc6/libstdc++6/zlib1g:amd64）"
command -v FEX >/dev/null 2>&1 && ok "FEX 可用" || warn "未装 FEX：gen_snapshot AOT 阶段可能崩（ppa:fex-emu/fex）"
need_abis=(arm64); [[ -z "$TARGET_PLATFORM" ]] && need_abis=(arm arm64 x64)
[[ " ${MODES[*]} " == *" release "* || -z "$TARGET_PLATFORM" ]] || need_abis=()
for abi in "${need_abis[@]}"; do
  gs="$ENG_DIR/android-$abi-release/linux-arm64/gen_snapshot"
  if [[ -x "$gs" ]] && "$gs" --version >/dev/null 2>&1; then ok "gen_snapshot(android-$abi) 可执行"
  elif [[ -f "$gs" ]]; then bad "gen_snapshot(android-$abi) 跑不起来（amd64 库或产物不对）"
  else bad "gen_snapshot(android-$abi) 缺失：tool/build_apk.sh --fix-artifacts"; fi
done

# ---- 本项目专属：NDK / CMake / Vulkan ----
if [[ -n "$ANDROID_SDK" ]]; then
  ndk_seen=0
  for ndkclang in "$ANDROID_SDK"/ndk/*/toolchains/llvm/prebuilt/*/bin/clang; do
    [[ -x "$ndkclang" ]] || continue
    ndk_seen=1
    ndkver=${ndkclang#*/ndk/}; ndkver=${ndkver%%/*}
    out=$("$ndkclang" --version 2>&1 | head -1) || out=""
    [[ "$out" == *"clang version"* ]] && ok "NDK clang $ndkver 可执行" || bad "NDK clang $ndkver 跑不起来：$out（缺 amd64 依赖库？）"
  done
  [[ $ndk_seen == 1 ]] || bad "无 NDK：llama.cpp 编译必需（sdkmanager \"ndk;27.0.12077973\"）"
  [[ -d "$ANDROID_SDK/cmake" || -d "$ANDROID_SDK"/cmake/* ]] && ok "SDK cmake" || warn "SDK cmake 缺失（externalNativeBuild 需要）"
fi

VK_SDK="${VULKAN_SDK:-$HOME/vulkan-sdk}"
if [[ -x "$VK_SDK/Bin/glslc" && -f "$VK_SDK/Include/vulkan/vulkan.hpp" ]]; then
  ok "Vulkan SDK $VK_SDK（ggml-vulkan 将启用）"
elif [[ "$(uname -m)" == "aarch64" ]]; then
  warn "无 Vulkan SDK（$VK_SDK）→ 本次只有 OpenCL+CPU。启用：tool/setup_vulkan_sdk.sh"
else
  warn "无 Vulkan SDK（$VK_SDK；Windows 装 LunarG 到 C:/VulkanSDK）→ 本次只有 OpenCL+CPU"
fi

# 签名（AGENTS 铁律：必须 CN=TongYiLite 正式证书，指纹见 EXPECTED_FP）
EXPECTED_FP="fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992"
if [[ -f "$PROJ_ROOT/android/key.properties" && -f "$PROJ_ROOT/android/key.jks" ]]; then
  ok "release 签名文件就位"
else
  warn "缺 android/key.jks|key.properties → release 将回退 debug 签名（不能覆盖安装正式版！新机器从安全备份拷入，见 docs/BUILD-linux.md ①）"
fi

[[ "$FAIL" == 0 ]] || { echo; echo "自检未通过，按 ✗ 提示修复。" >&2; exit 1; }
[[ "$RUN_CHECK_ONLY" == 1 ]] && { echo; echo "自检全部通过。"; exit 0; }

# ---------------------------------------------------------------- artifacts 修复
if [[ "$FIX_ARTIFACTS" == 1 ]]; then
  echo "== 补齐 flutter 的 arm64 主机 gen_snapshot"
  [[ -n "$ENGINE" ]] || { echo "缺 engine.version" >&2; exit 1; }
  for abi in arm arm64 x64; do
    for mode in release profile; do
      src="android-$abi-$mode"; dst="$ENG_DIR/$src/linux-arm64"; tmp="$(mktemp -d)"
      url="$STORAGE_BASE/flutter_infra_release/flutter/$ENGINE/$src/linux-x64.zip"
      curl -fsSL --retry 3 -o "$tmp/a.zip" "$url" || { echo "  下载失败 $url" >&2; continue; }
      unzip -oq "$tmp/a.zip" -d "$tmp"; [[ -f "$tmp/gen_snapshot" ]] || continue
      mkdir -p "$dst"
      install -m 755 "$tmp/gen_snapshot" "$dst/gen_snapshot.bin"
      cat > "$dst/gen_snapshot" <<'WRAP'
#!/bin/sh
# 官方只发 linux-x64 版 gen_snapshot；qemu-user 跑它会自身崩溃，优先 FEX。
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v FEX >/dev/null 2>&1; then exec FEX "$d/gen_snapshot.bin" "$@"; fi
exec "$d/gen_snapshot.bin" "$@"
WRAP
      chmod 755 "$dst/gen_snapshot"; rm -rf "$tmp"
      printf '  ✓ %-32s\n' "$src/linux-arm64"
    done
  done; echo
fi

# ---------------------------------------------------------------- 构建
cd "$PROJ_ROOT"
export ANDROID_HOME="$ANDROID_SDK" ANDROID_SDK_ROOT="$ANDROID_SDK" JAVA_HOME="$JAVA17"
export VULKAN_SDK="$VK_SDK"

# ninja 并行度按可用内存自适应（llama.cpp 单个 TU 峰值 ~0.5-1G；vLLM 常驻机慎用满核）
mem_gib=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 8)
cores=$(nproc)
par=$(( mem_gib / 2 )); (( par < 1 )) && par=1; (( par > cores )) && par=$cores
export CMAKE_BUILD_PARALLEL_LEVEL="$par"
echo "== 并行度：ninja=$par（cores=$cores, MemAvailable=${mem_gib}G），gradle worker 见机器层配置"

if [[ "$CLEAN_NATIVE" == 1 ]]; then
  echo "== 清 native 缓存全量重编（防 .so 陈旧）"
  # 注意：残留的 glslc/vulkan-shaders-gen 进程会锁 .cxx（AGENTS），先停
  pkill -f 'vulkan-shaders-gen|glslc' 2>/dev/null || true
  "$PROJ_ROOT/android/gradlew" --stop >/dev/null 2>&1 || true
  rm -rf "$PROJ_ROOT/android/app/.cxx" "$PROJ_ROOT/build/app/intermediates/cxx" "$PROJ_ROOT/build/cxx"
fi

[[ "$RUN_ANALYZE" == 1 ]] && { echo "== flutter analyze"; "$FLUTTER" analyze --no-pub; }
echo "== flutter pub get"; "$FLUTTER" pub get

APKS=()
for MODE in "${MODES[@]}"; do
  args=(build apk "--$MODE")
  [[ -n "$TARGET_PLATFORM" && "$MODE" != debug ]] && args+=(--target-platform="$TARGET_PLATFORM")
  echo "== flutter ${args[*]}"
  "$FLUTTER" "${args[@]}"
  APK="build/app/outputs/flutter-apk/app-$MODE.apk"
  [[ -f "$APK" ]] || { echo "构建结束但没找到 $APK" >&2; exit 1; }
  APKS+=("$APK")
done

# ---------------------------------------------------------------- 产物验收
APKSIGNER="$(ls "$ANDROID_SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
for APK in "${APKS[@]}"; do
  echo
  echo "产物：$PROJ_ROOT/$APK"
  printf '体积：%s   sha256：%s…\n' "$(du -h "$APK" | cut -f1)" "$(sha256sum "$APK" | cut -c1-16)"
  if command -v unzip >/dev/null 2>&1; then
    n_so=$(unzip -l "$APK" | grep -c 'lib/arm64-v8a/.*\.so')
    echo "原生库：$n_so 个 .so（arm64）；关键后端："
    unzip -l "$APK" | grep -oE 'lib/arm64-v8a/lib(ggml[^ ]*|llama[^ ]*|mtmd|app|flutter|turnip[^ ]*|opencl_stub)\.so' | sed 's/^/    /' | sort -u
  fi
  # 签名验收（release 必须是正式证书；debug 允许同证书——本项目 build.gradle 已统一）
  if [[ -n "$APKSIGNER" && "$MODE" == "release" || -n "$APKSIGNER" ]]; then
    dn=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*certificate DN: //p' | head -1)
    fp=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*SHA-256 digest: //p' | head -1 | tr -d ':')
    if [[ "$fp" == "$EXPECTED_FP" ]]; then
      ok "签名验收通过：$dn"
    else
      bad "签名不符！$dn ($fp) ≠ CN=TongYiLite/$EXPECTED_FP（AGENTS 铁律：检查 android/key.jks）"
      exit 1
    fi
  fi
done

# native 新鲜度提示（AGENTS：.so 陈旧坑）
[[ "$CLEAN_NATIVE" == 0 ]] && warn "如本次改过 cpp/ 或 third_party/llama.cpp，请用 --clean-native 重编（up-to-date 判定会跳过）"

if [[ "$RUN_INSTALL" == 1 ]]; then
  # 安装验收必须机检 "Success"：adb 在多设备/offline 时会打印一堆错误却**仍然退出 0**
  # （2026-10-20 实测：手机 abb_exec 崩成 offline + 另一台 unauthorized，脚本"成功"收尾，
  #  实际一个包都没装进去）。只信 adb 的退出码 = 自欺。
  install_one() {   # $1=device $2=apk
    local dev="$1" apk="$2" out
    for extra in "" " -t"; do
      out="$(adb -s "$dev" install -r$extra "$apk" 2>&1)"; echo "$out"
      grep -q "Success" <<<"$out" && return 0
    done
    return 1
  }

  if ! command -v adb >/dev/null 2>&1; then
    echo "无 adb，跳过安装。" >&2
  else
    mapfile -t DEVS < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    if [[ -n "${DEVICE:-}" ]]; then
      DEVS=("$DEVICE")
    elif [[ ${#DEVS[@]} -eq 0 ]]; then
      echo "无在线 adb 设备，跳过安装（bash scripts/adb-wifi-remote.sh 重连；" >&2
      echo "  掉 offline/tcp 模式失效时要回 USB 主机跑 scripts/adb-wifi.ps1）。" >&2
      DEVS=()
    elif [[ ${#DEVS[@]} -gt 1 ]]; then
      bad "多台设备在线（${DEVS[*]}）——adb 不指定 -s 会静默失败。请 DEVICE=<ip:5555> 重跑 --install。"
      exit 1
    fi
    for DEV in "${DEVS[@]}"; do
      for APK in "${APKS[@]}"; do
        echo "== adb install -r -> $DEV ($(basename "$APK"))"
        # 绝不 uninstall：会清掉已下载的端侧模型缓存（AGENTS 铁律）
        install_one "$DEV" "$PROJ_ROOT/$APK" || {
          bad "安装失败：$DEV / $APK —— 先 `adb devices` 看是不是 offline/unauthorized"
          exit 1
        }
      done
    done
  fi
fi
echo; echo "== 完成。APK 目录：$PROJ_ROOT/build/app/outputs/flutter-apk/"
