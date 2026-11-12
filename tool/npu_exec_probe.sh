#!/usr/bin/env bash
# [npu-line M2 C-3] filesDir 可执行性实测（SELinux/W^X 判例采集）。
#
# 背景：NpuAssets.extract 把 assets/npu_libs 解包到
#   /data/data/com.dgxspark.tongyilite/files/npu_m1/
# （MainActivity.handleExtractNpuAssets → NpuAssets.extract）。App targetSdk 34，
# Android 10+ 起 app_data_file 上的 execve 通常被 SELinux dontaudit/W^X 拦死
# （build.gradle.kts 注释「app 数据目录不可 exec」即此判例），而
# hyb_jni.cpp 的链发起方式是 fork+exec chain_run5。本脚本实测两条路径：
#
#   [控制组] /data/local/tmp/npu_exec_probe/chain_run5 —— shell 域，预期可 exec
#   [实验组] run-as 代理把二进制拷进 App filesDir/npu_exec_probe/ 再以 App
#            uid+context exec —— 等价复现 App 自己的 execve（run-as 会切到
#            App 的 SELinux context；untrusted_app 近似度在输出 id -Z 里自查）
#
# 哑参数：chain_run5 无参数只打 usage 后 return 1 —— 打出 usage/CR5_* 即
# execve 已成功；「Permission denied」=EACCES（SELinux 拦），
# 「Exec format error」=ENOEXEC（ELF 架构/格式错）。
#
# 用法（Git Bash；设备空闲时跑）：
#   bash tool/npu_exec_probe.sh                # 只读体检（getenforce/ls/avc tail）
#   CONFIRM=1 bash tool/npu_exec_probe.sh      # 追加 push+exec 实验（自清理）
# env 覆盖：DEV / ADB / BIN（推送源，默认 assets/npu_libs/chain_run5）/ PKG
#
# 纪律：默认模式对设备零改动；CONFIRM 模式只写 /data/local/tmp/npu_exec_probe
# 与 filesDir/npu_exec_probe 两个探针专属目录，结束即删，不碰 npu_m1 本体。
#
# 结论用途：实验组 EXEC_OK → App 可直接 fork+exec filesDir 二进制；
# EACCES → 落备选：runner 编成 lib*.so 由 libhyb_jni dlopen 后进程内跑
# （execve 不发生，W^X 不适用），或 /data/local/tmp staging（需 adb，非出货形态）。
set -uo pipefail
export MSYS2_ARG_CONV_EXCL="*" MSYS_NO_PATHCONV=1

DEV="${DEV:-<redacted-tailscale>:5555}"
ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
PKG="${PKG:-com.dgxspark.tongyilite}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$REPO/android/app/assets/npu_libs/chain_run5}"
D_PROBE=/data/local/tmp/npu_exec_probe
CONFIRM="${CONFIRM:-}"

[ -x "$ADB" ] || ADB="$(command -v adb || true)"
[ -n "$ADB" ] || { echo "PROBE_FAIL no adb (set ADB=)" >&2; exit 2; }
sh_out() { "$ADB" -s "$DEV" shell "$@" 2>&1; }

echo "== npu_exec_probe dev=$DEV pkg=$PKG confirm=${CONFIRM:-0} =="

# ---------- 只读体检 ----------
echo "-- selinux enforce: $(sh_out getenforce | tr -d '\r')"
echo "-- sdk: $(sh_out getprop ro.build.version.sdk | tr -d '\r')"
echo "-- device npu_m1 (batch dir, 只读):"
sh_out ls -la /data/local/tmp/npu_m1 2>&1 | head -8
echo "-- app filesDir 现状（run-as，若 App 未装/debuggable 会报）:"
sh_out run-as "$PKG" ls -laZ files/npu_m1 2>&1 | head -8
echo "-- logcat avc 近况（exec/execute 相关）:"
"$ADB" -s "$DEV" logcat -d 2>&1 | grep -i "avc:" | grep -iE "execute|exec" | tail -10
echo "READONLY_OK（CONFIRM=1 追加 push+exec 实验）"
[ "$CONFIRM" = "1" ] || exit 0

# ---------- CONFIRM=1：exec 实验 ----------
[ -f "$BIN" ] || { echo "PROBE_FAIL push 源不存在: $BIN" >&2; exit 2; }
echo "-- push 源: $BIN ($(wc -c <"$BIN") bytes)"

classify() { # $1=组名 $2=输出 $3=退出码
    local tag="$1" out="$2" rc="$3"
    if grep -qE "usage: chain_run5|CR5_" <<<"$out"; then
        echo "PROBE_RESULT $tag EXEC_OK (rc=$rc)"
    elif grep -qi "permission denied" <<<"$out"; then
        echo "PROBE_RESULT $tag EACCES (rc=$rc)  ← SELinux/W^X 拦截 execve"
    elif grep -qi "exec format error" <<<"$out"; then
        echo "PROBE_RESULT $tag ENOEXEC (rc=$rc)  ← ELF 架构/格式错（检查是否 arm64）"
    else
        echo "PROBE_RESULT $tag UNKNOWN (rc=$rc) out=[$out]"
    fi
}

# 控制组：shell 域 /data/local/tmp
sh_out mkdir -p "$D_PROBE"
"$ADB" -s "$DEV" push "$BIN" "$D_PROBE/chain_run5" >/dev/null
sh_out chmod 755 "$D_PROBE/chain_run5"
out="$(sh_out "$D_PROBE/chain_run5" 2>&1)"; rc=$?
classify ctl_shell_tmp "$out" "$rc"

# 实验组：run-as 代理进 App filesDir（等价 App 自身 execve 语境）
out="$(sh_out run-as "$PKG" sh -c \
  "mkdir -p files/npu_exec_probe && cp $D_PROBE/chain_run5 files/npu_exec_probe/chain_run5 && chmod 755 files/npu_exec_probe/chain_run5 && id -Z && ls -Z files/npu_exec_probe/chain_run5 && files/npu_exec_probe/chain_run5 2>&1; echo RCX=\$?")"
rc=$?
echo "$out" | grep -E "^u:|^RCX=" | head -4
classify app_filesdir "$(grep -v '^RCX=' <<<"$out")" "$(sed -n 's/^RCX=//p' <<<"$out" | tail -1)"

echo "-- 实验现场 avc（若有 denial）:"
"$ADB" -s "$DEV" logcat -d 2>&1 | grep -i "avc:" | grep -iE "execute|app_data_file" | tail -10

# 自清理（只删探针目录）
sh_out rm -rf "$D_PROBE"
sh_out run-as "$PKG" rm -rf files/npu_exec_probe
echo "PROBE_DONE（判读：EXEC_OK=可直接 fork+exec；EACCES=走 dlopen-runner 备选）"
