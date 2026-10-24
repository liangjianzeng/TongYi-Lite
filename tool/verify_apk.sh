#!/usr/bin/env bash
# verify_apk.sh —— APK 产物验收的**唯一真源**（签名 / 体积 / 原生库清单）。
#
# 为什么单独成文件：验收逻辑原来内嵌在 build_apk.sh 里，于是"这条门禁到底会不会红"**无法单独验证**
# —— 想证红就得整套重编（30 分钟起），实际上没人会去证，等于一条信仰门禁（§11-C 那族病：
# 门禁承诺的检查其实不存在）。抽出来之后它可以被单独跑、单独证红，build_apk.sh 只负责调用。
#
# 用法：bash tool/verify_apk.sh <apk 路径> [<apk 路径>…]
# 退出码：0 = 全部通过；1 = 签名不符 / 验不了 / 文件缺失；2 = 用法错。
#
# 兜不住的口子（诚实声明）：
#   · 机器上没有 apksigner（缺 build-tools 或 ANDROID_SDK 没指对）→ **按失败处理**（exit 1），
#     不再"跳过即通过"；确实要在没有 build-tools 的机器上过，显式写 SKIP_SIGN_CHECK=1，
#     那会在输出里留下一行大大的 ! 而不是一个 ✓。
set -uo pipefail

# AGENTS 铁律：正式证书 CN=TongYiLite（O=DGXSpark），指纹见下（可用环境变量覆盖以便自证红）。
EXPECTED_FP="${EXPECTED_FP:-fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992}"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/android-sdk}}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

if [[ $# -lt 1 ]]; then
  echo "用法：bash tool/verify_apk.sh <apk> [<apk>…]" >&2
  exit 2
fi

FAIL=0
APKSIGNER="$(ls "$ANDROID_SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"

for APK in "$@"; do
  echo "产物：$APK"
  if [[ ! -f "$APK" ]]; then
    bad "文件不存在：$APK（先构建，或检查路径）"
    FAIL=1
    continue
  fi
  printf '体积：%s   sha256：%s…\n' "$(du -h "$APK" | cut -f1)" "$(sha256sum "$APK" | cut -c1-16)"
  if command -v unzip >/dev/null 2>&1; then
    n_so=$(unzip -l "$APK" | grep -c 'lib/arm64-v8a/.*\.so' || true)
    echo "原生库：$n_so 个 .so（arm64）；关键后端："
    unzip -l "$APK" | grep -oE 'lib/arm64-v8a/lib(ggml[^ ]*|llama[^ ]*|mtmd|app|flutter|turnip[^ ]*|opencl_stub)\.so' | sed 's/^/    /' | sort -u
  fi

  if [[ -z "$APKSIGNER" ]]; then
    if [[ "${SKIP_SIGN_CHECK:-0}" == "1" ]]; then
      warn "找不到 apksigner（ANDROID_SDK=$ANDROID_SDK），签名验收被 **SKIP_SIGN_CHECK=1 显式跳过** —— 这不算验过"
    else
      bad "找不到 apksigner（ANDROID_SDK=$ANDROID_SDK）：验不了就等于没过。装 build-tools 或设 ANDROID_HOME；"
      bad "确实要在无 build-tools 的机器上过，显式设 SKIP_SIGN_CHECK=1（会在输出里留下 ! 而不是 ✓）"
      FAIL=1
    fi
    continue
  fi

  certs="$("$APKSIGNER" verify --print-certs "$APK" 2>&1)" || {
    bad "apksigner verify 失败（未签名？签名损坏？）：$(echo "$certs" | head -1)"
    FAIL=1
    continue
  }
  dn="$(echo "$certs" | sed -n 's/.*certificate DN: //p' | head -1)"
  fp="$(echo "$certs" | sed -n 's/.*SHA-256 digest: //p' | head -1 | tr -d ':')"
  if [[ "$fp" == "$EXPECTED_FP" ]]; then
    ok "签名验收通过：$dn"
  else
    bad "签名不符！$dn ($fp) ≠ CN=TongYiLite/$EXPECTED_FP（AGENTS 铁律：检查 android/key.jks）"
    FAIL=1
  fi
done

[[ "$FAIL" == 0 ]] || exit 1
exit 0
