#!/usr/bin/env bash
# [npu-line M2 C-3 review rework] NPU 链资产 staging（W^X 布局，P0-3）：
# App 混合调度（hyb_jni.cpp）所需的运行时三件套按可执行性分两个分发面：
#
#   a) chain_run5          WSL NDK r27c 编 npu-line/probe_m1/dec2/chain_run5.cpp
#                          （dlopen 方案，只依赖 QNN 头文件，不链 QNN 库；
#                          include 目录 = QAIRT SDK $SDK/include/QNN）
#                          → **jniLibs/arm64-v8a/libchain_run5_exec.so**
#                          （app_data_file 禁 exec，可执行体必须走 jniLibs +
#                          useLegacyPackaging → nativeLibraryDir system_file）
#   b) manifest_pre2_A/B/C 设备 /data/local/tmp/npu_m1 只读 pull（dec2p 三段
#                          闸门 manifest；若含绝对路径则改写为 chainDir 相对
#                          语义——现网三份实测全相对，改写只是护栏）
#                          → assets/npu_libs（非可执行件，extract 到 filesDir；
#                          chainDir/lib symlink→nativeLibraryDir 补 dlopen 相对路径）
#   c) QNN 运行库四件套    设备 npu_m1/lib 只读 pull：libQnnHtp.so、
#                          libQnnHtpV73Skel.so（740=Hexagon V73）、
#                          libQnnHtpV73Stub.so、libQnnSystem.so
#                          → **jniLibs/arm64-v8a/**（同上，dlopen 真身位）
#
# 纪律：设备侧只读（ls/pull），本脚本对设备零改动。
#
# 用法（Git Bash）：
#   bash tool/stage_npu_assets.sh            # 全量（build + pull + 校验 + README）
#   SKIP_BUILD=1 bash tool/stage_npu_assets.sh   # 复用上次编译产物
#   SKIP_PULL=1  bash tool/stage_npu_assets.sh   # 只重编 chain_run5
# 依赖：adb（或 ADB 指定路径；缺失时回落 mcp5_94_adbsock.py 纯协议 pull）；
#       WSL Ubuntu-22.04 + NDK r27c + QAIRT SDK 头（变量可覆盖）。
#
# 真机核对遗留（README TODO-B）：42 个 dec2p_l{k}_ctx.bin（~3.9GB）不随 APK，
# 另行 staging 到 filesDir/npu_m1；libQnnHtpPrepare.so/libQnnModelDlc.so/
# libCalculator_skel.so 运行时是否被间接 dlopen 待实机 CR5_FAIL 证据定夺。
set -uo pipefail
export MSYS2_ARG_CONV_EXCL="*"

DEV="${DEV:-<redacted-tailscale>:5555}"
ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
WSL_DIST="${WSL_DIST:-Ubuntu-22.04}"
NDK_WSL="${NDK_WSL:-/home/liang/m4/android-ndk-r27c}"
QNN_INC="${QNN_INC:-/mnt/e/MyLLM/qairt/2.44.0.260225/include/QNN}"
SDK_TAG="${SDK_TAG:-2.44.0.260225}"
D_DEV=/data/local/tmp/npu_m1
REPO="$(cd "$(dirname "$0")/.." && pwd)"
A="$REPO/android/app/src/main/assets/npu_libs"   # 必须是 src/main/assets：
# AGP 只打包 sourceSets 的 assets（曾经的 android/app/assets 不在打包源里，
# 2026-11-12 审查发现 manifest 全程没进 APK）
J="$REPO/android/app/src/main/jniLibs/arm64-v8a"
SRC="$REPO/npu-line/probe_m1/dec2/chain_run5.cpp"
WORK="${WORK:-E:/MyLLM_exp/hyb_c/stage_work}"
QNN_LIBS=(libQnnHtp.so libQnnHtpV73Skel.so libQnnHtpV73Stub.so libQnnSystem.so)
MANIFESTS=(manifest_pre2_A manifest_pre2_B manifest_pre2_C)

fail() { echo "✗ $1" >&2; exit 1; }
mkdir -p "$WORK/lib" "$A" "$J"

# ---- adb 门面：优先 platform-tools adb；缺失回落 mcp5_94_adbsock 纯协议 ------
have_adb=0
if [ -x "$ADB" ] || command -v "$ADB" >/dev/null 2>&1; then have_adb=1; fi
dshell() {  # dshell <device-cmd>
    if [ "$have_adb" = 1 ]; then
        "$ADB" -s "$DEV" shell "$1" 2>&1 | tr -d '\r'
    else
        python - "$DEV" "$1" <<'PY'
import sys
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock
print(AdbSock(sys.argv[1]).shell(sys.argv[2]), end="")
PY
    fi
}
dpull() {  # dpull <remote> <local> —— 设备高负载时 sync 通道偶发抽风，重试 3 次
    local try
    for try in 1 2 3; do
        _dpull_once "$1" "$2" && return 0
        echo "  pull $1 第 $try 次失败，2s 后重试" >&2
        sleep 2
    done
    fail "pull $1 三连失败（设备忙？等 50-prompt 批量结束再跑，或 SKIP_PULL=1 复用上次）"
}
_dpull_once() {
    if [ "$have_adb" = 1 ]; then
        "$ADB" -s "$DEV" pull "$1" "$2" >/dev/null 2>&1 && [ -s "$2" ] && return 0 || return 1
    else
        python - "$DEV" "$1" "$2" <<'PY'
import sys, os
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock
os.makedirs(os.path.dirname(sys.argv[3]) or ".", exist_ok=True)
AdbSock(sys.argv[1]).pull(sys.argv[2], sys.argv[3])
PY
        [ -s "$2" ]
    fi
}

wslpath_u() {  # Win/MSYS 路径 → WSL 路径（无 wslpath 时手剥盘符）
    if command -v wslpath >/dev/null 2>&1; then wslpath -au "$1"; return; fi
    case "$1" in
        [A-Za-z]:*) echo "/mnt/$(echo "${1:0:1}" | tr 'A-Z' 'a-z')${1:2}" ;;
        /*) echo "/mnt/${1:1:1}/${1:3}" ;;
        *) echo "$1" ;;
    esac
}

echo "== 1/4 编译 chain_run5（WSL NDK，源码 = $SRC）=="
if [ "${SKIP_BUILD:-0}" = "1" ] && [ -s "$WORK/chain_run5_built" ]; then
    echo "SKIP_BUILD=1，复用 $WORK/chain_run5_built"
else
    [ -f "$SRC" ] || fail "缺源 $SRC"
    wsl.exe -d "$WSL_DIST" -- bash -c \
        "\"$NDK_WSL/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++\" \
--target=aarch64-linux-android29 -O2 -std=c++17 -Wall \
-I\"$QNN_INC\" \"$(wslpath_u "$SRC")\" \
-ldl -o \"$(wslpath_u "$WORK/chain_run5_built")\"" \
        || fail "chain_run5 编译失败（NDK_WSL=$NDK_WSL QNN_INC=$QNN_INC）"
fi
file "$WORK/chain_run5_built" 2>/dev/null | grep -q "ARM aarch64" \
    || fail "产物不是 aarch64 ELF：$WORK/chain_run5_built"
# [P0-3] 可执行体走 jniLibs（useLegacyPackaging 安装期解出 system_file 真身，
# App uid 可 execve/dlopen；app_data_file 禁 exec）——改名 lib*.so 入包
cp -f "$WORK/chain_run5_built" "$J/libchain_run5_exec.so"

echo "== 2/4 设备只读核对（$DEV）=="
if [ "${SKIP_PULL:-0}" != "1" ]; then
    if [ "$have_adb" = 1 ]; then
        "$ADB" -s "$DEV" get-state >/dev/null 2>&1 || fail "设备 $DEV 不在线"
    fi
    dshell "ls $D_DEV" | grep -q manifest_pre2_A || fail "设备缺 $D_DEV/manifest_pre2_*"
    for f in "${QNN_LIBS[@]}"; do
        dshell "ls $D_DEV/lib/$f" | grep -q "$f" || fail "设备缺 $D_DEV/lib/$f"
    done
    # 全清单留档（lib 下其余 V68/V69/V75/…、Prepare/Dlc/Calculator 是否运行必需 → README TODO-B）
    dshell "ls -la $D_DEV/lib" > "$WORK/device_lib_inventory.txt"

    echo "== 3/4 只读 pull（manifest×3 + QNN×4）=="
    for f in "${MANIFESTS[@]}"; do dpull "$D_DEV/$f" "$WORK/$f"; done
    for f in "${QNN_LIBS[@]}"; do dpull "$D_DEV/lib/$f" "$WORK/lib/$f"; done
fi
for f in "${MANIFESTS[@]}"; do [ -s "$WORK/$f" ] || fail "缺 $WORK/$f（去掉 SKIP_PULL 重跑）"; done
for f in "${QNN_LIBS[@]}"; do [ -s "$WORK/lib/$f" ] || fail "缺 $WORK/lib/$f"; done

# manifest 路径参数化护栏：现网三份全相对；若上游哪天塞了绝对路径，把设备目录
# 前缀剥成相对；剥不动的其他绝对路径直接失败（拒绝把 /data/local/tmp 语义带进 APK）。
for f in "${MANIFESTS[@]}"; do
    if grep -q "/" "$WORK/$f"; then
        sed "s|$D_DEV/||g" "$WORK/$f" > "$WORK/$f.relsed"
        if grep -qE "(^| )/" "$WORK/$f.relsed"; then
            fail "$f 含无法剥除的绝对路径，人工核对后再分发"
        fi
        cp -f "$WORK/$f.relsed" "$A/$f"
        echo "  $f: 已剥设备目录前缀 → 相对"
    else
        cp -f "$WORK/$f" "$A/$f"
    fi
done
for f in "${QNN_LIBS[@]}"; do cp -f "$WORK/lib/$f" "$J/$f"; done

echo "== 4/4 校验 + README =="
{
    echo "# npu 链资产 — NPU 分层链运行时（npu-line M2 Phase C-3 review rework，本文件由 tool/stage_npu_assets.sh 生成）"
    echo
    echo "布局（W^X，P0-3）：可执行体走 **jniLibs**（arm64-v8a）＋ useLegacyPackaging"
    echo "安装期解出真文件到 nativeLibraryDir（system_file，App uid 可 execve/dlopen）；"
    echo "manifest 走 assets → NpuAssets.extract 解包 filesDir/npu_m1（链 cwd/产物区），"
    echo "chainDir/lib 由 extract 建 symlink → nativeLibraryDir（chain_run5 的"
    echo "dlopen(\"./lib/libQnnHtp.so\") 相对 cwd 解析到真身）。字节与设备"
    echo "/data/local/tmp/npu_m1 同源。"
    echo
    echo "| 资产 | 位置 | 字节 | sha256 | 来源 |"
    echo "|---|---|---|---|---|"
    echo "| libchain_run5_exec.so | jniLibs/arm64-v8a | $(wc -c < "$J/libchain_run5_exec.so") | $(sha256sum "$J/libchain_run5_exec.so" | cut -d' ' -f1) | WSL NDK r27c 编 npu-line/probe_m1/dec2/chain_run5.cpp（QAIRT $SDK_TAG QNN 头，-ldl）|"
    for f in "${MANIFESTS[@]}"; do
        echo "| $f | assets/npu_libs | $(wc -c < "$A/$f") | $(sha256sum "$A/$f" | cut -d' ' -f1) | 设备只读 pull（dec2p 三段闸门 manifest，42 层 = A l0-13/B l14-27/C l28-41）|"
    done
    for f in "${QNN_LIBS[@]}"; do
        echo "| $f | jniLibs/arm64-v8a | $(wc -c < "$J/$f") | $(sha256sum "$J/$f" | cut -d' ' -f1) | 设备只读 pull npu_m1/lib |"
    done
    cat <<'MD'

TODO-B（实机核对，见 tool/npu_exec_probe.sh 与设备 CR5 日志）：
- 42 个 `dec2p_l{k}_ctx.bin`（~3.9GB）**不随 APK**——需另行 staging 到
  filesDir/npu_m1/（owner 推送 / 后续 OTA 资产通道）。缺件表现 = chain_run5
  段日志 `CR5_FAIL open ctx`，prefill 回包 stage=prefill_seg 带 log_tail。
- `libQnnHtpPrepare.so`(85M，建图期库，执行 context-binary 大概率不需要)、
  `libQnnModelDlc.so`、`libCalculator_skel.so`：设备 lib/ 实存，若运行期
  dlopen 需求出现（CR5_FAIL dlopen/dlsym），用本脚本从设备补 pull 四件套清单。
- 其余 arch 变体（V68/V69/V75/V79/V81 Skel/Stub）740 机不加载，不分发。
- strip 豁免已落地：build.gradle.kts packaging.jniLibs.keepDebugSymbols
  用 "**/<文件名>" 形式豁免本清单五件（AGP 8.7 的 compileGlob 对裸名补
  "/name" 永不命中、模式需自带 "**/"；验证须删
  build/app/intermediates/stripped_native_libs/ 强制 strip 全量重跑）。
  包内字节 = 本 README sha256 台账（2026-11-12 zipfile 全五件比对通过）。
MD
} > "$A/README.md"
cd "$A" && find . -type f -printf "%10s  %P\n" | sort -k2
cd "$J" && find . -maxdepth 1 -name "libchain_run5_exec.so" -o -maxdepth 1 -name "libQnn*" | sort \
    | xargs -I{} sh -c 'printf "%10s  jniLibs/arm64-v8a/%s\n" "$(wc -c < "{}")" "{}"'
echo "STAGE_NPU_ASSETS_OK"
