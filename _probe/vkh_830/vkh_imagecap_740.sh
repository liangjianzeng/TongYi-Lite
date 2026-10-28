#!/usr/bin/env bash
# vkh_imagecap_740.sh — 镜像能力探针腿侧枪（R-117，宿主侧驱动；740 = 父车道，父跑）
#
# 目的：**先于任何 diff** 判定 CL_DEVICE_IMAGE_MAX_BUFFER_SIZE 是否容得下 LFM 的
#   q_img（image_width = 25 165 824 px，= 已跑通的 ling 12 582 912 px 的 2 倍），
#   并判定 **A 路的姿势（子缓冲 origin 之上建 image）在 rusticl 上是否可行**。
#
# 与腿同栈（哑火 #25 堵雷）：740 的腿 = glibc CLRT sysroot + Mesa ICD，不是 Android
#   /vendor/lib64/libOpenCL.so。本枪用同一 $R/$LOADER/$LP/$ICD 跑探针，并强制校验
#   探针报告的平台厂商是 Mesa —— 若测到 vendor Adreno 驱动，一律红牌作废（假 PASS 比没测更坏）。
#
# 用法：  bash vkh_imagecap_740.sh            # 真跑
#         DRY=1 bash vkh_imagecap_740.sh      # 排练（只打印，不碰设备）
#   覆盖：ADB="adb -P 15037 -s 100.109.138.2:5555"  TEMP_GATE=400  FIX_STAYON=1
#         VKH_IC_LFM_W=25165824 VKH_IC_LING_W=12582912 VKH_IC_Q_LAYER=1572864 VKH_IC_E=64 VKH_IC_ES_BASE=32
set -uo pipefail
ADB=${ADB:-"adb -P 15037 -s 100.109.138.2:5555"}
DRY=${DRY:-0}
TEMP_GATE=${TEMP_GATE:-400}          # 纯 I/O 档
FIX_STAYON=${FIX_STAYON:-0}
BIN_HOST=${BIN_HOST:-"$(dirname "$0")/dist/vkh_imagecap"}
D=/data/local/tmp/vkh_ic
R=/data/local/tmp/mesa_clrt_1026     # 与父 b_line 同栈
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
OUT=$R/out
TS=$(date +%m%d_%H%M%S)
sh_d() { if [ "$DRY" = "1" ]; then echo "DRY| $ADB shell '$1'"; else $ADB shell "$1"; fi; }
abort() { echo "#### IC_ABORT reason=$1"; exit 1; }

[ "$DRY" = "1" ] || { command -v adb >/dev/null || abort no_adb; $ADB shell 'echo IC_PING' 2>/dev/null | grep -q IC_PING || abort device_offline; }

# ── 闸门①：温闸（纯 I/O = 400）
if [ "$DRY" = "1" ]; then T=0; S=0; BUSY=""; echo "DRY| 闸门①②③ 排练态跳过（真跑才机检）"
else
T=$(sh_d "dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'" | tr -dc '0-9')
echo "#### IC_GATE temp=${T:-?} limit=$TEMP_GATE"
[ "${T:-0}" -le "$TEMP_GATE" ] || abort "hot_${T}_gt_${TEMP_GATE}"

# ── 闸门②：stayon 机检（屏幕绝不许常亮——AGENTS.md 绝对铁律；本枪全程不点亮屏幕）
S=$(sh_d "settings get global stay_on_while_plugged_in" | tr -d '\r[:space:]')
[ -z "$S" ] && S=null
echo "#### IC_GATE stay_on_while_plugged_in=$S"
if [ "$S" != "0" ] && [ "$S" != "null" ]; then
  if [ "$FIX_STAYON" = "1" ]; then sh_d "svc power stayon false" >/dev/null; echo "#### IC_GATE stayon_zeroed=1（追查是谁设的，入账）";
  else abort "stayon=$S_nonzero（父车道不擅动，置 FIX_STAYON=1 才归零）"; fi
fi

# ── 闸门③：绝不惊动在跑的腿（740 归父；有腿在跑一律让路）
BUSY=$(sh_d "ps -A 2>/dev/null | grep -E 'ling_e2e|llama-cli|lfm2|ling_e2e_v4ld' | grep -v grep | head -3")
[ -n "$BUSY" ] && abort "leg_running（父腿在跑，探针让路）: $(echo "$BUSY" | tr '\n' '|')"
fi

# ── 闸门④：装载证明 = 驱动归属证明（探针必须与腿同栈同驱动）
[ "$DRY" = "1" ] || { [ -f "$BIN_HOST" ] || abort "no_artifact $BIN_HOST（先跑 vkh_imagecap_build.sh）"; }
LOCAL_MD5=$( [ -f "$BIN_HOST" ] && md5sum "$BIN_HOST" | awk '{print $1}' || echo MISSING )
echo "#### IC_ARTIFACT host_md5=$LOCAL_MD5"
sh_d "mkdir -p $D" >/dev/null
if [ "$DRY" = "1" ]; then
  echo "DRY| 跳过 push 与双端 md5 对拍（排练态无设备，比对无意义；真跑必过此闸）"
else
  $ADB push "$BIN_HOST" "$D/vkh_imagecap" >/dev/null 2>&1 || abort push_failed
  sh_d "chmod 755 $D/vkh_imagecap" >/dev/null
  DEV_MD5=$(sh_d "sha256sum $D/vkh_imagecap 2>/dev/null | cut -c1-32" | tr -d '\r[:space:]')
  HOST_MD5=$(sha256sum "$BIN_HOST" | cut -c1-32)
  echo "#### IC_MD5 host=$HOST_MD5 device=$DEV_MD5"
  [ -n "$DEV_MD5" ] && [ "$HOST_MD5" = "$DEV_MD5" ] || abort "md5_mismatch（哑火 #23 同款，双端真 sha256 才算推成）"
fi

# ── 开跑（与腿同 LOADER/LP/ICD；无头，绝不 wake screen）
# RUSTICL_ENABLE=kgsl 必须与腿逐字一致：少了它 rusticl 可能不绑 Adreno 而落 llvmpipe ⇒ 镜像上限另算 = 假 PASS
ENVV="RUSTICL_ENABLE=kgsl VKH_IC_Q_LAYER=${VKH_IC_Q_LAYER:-1572864} VKH_IC_E=${VKH_IC_E:-64} VKH_IC_ES_BASE=${VKH_IC_ES_BASE:-32} VKH_IC_LING_W=${VKH_IC_LING_W:-12582912} VKH_IC_LFM_W=${VKH_IC_LFM_W:-25165824}"
CMD="cd $D && $ENVV LD_LIBRARY_PATH=$LP OPENCL_ICD_VENDORS=$ICD OCL_ICD_VENDORS=$ICD $LOADER $D/vkh_imagecap 2>&1"
LOG=/tmp/ic_740_${TS}.log
if [ "$DRY" = "1" ]; then echo "DRY| $CMD"; exit 0; fi
$ADB shell "$CMD" | tee "$LOG"

# ── 判读（机检，不做成人眼终审）
cp "$LOG" "$OUT/imagecap_740_${TS}.log" 2>/dev/null || $ADB shell "cp $OUT/imagecap_740_${TS}.log $OUT/ 2>/dev/null"
V=$(grep -a '#### IMAGECAP_VERDICT' "$LOG" | tail -1)
[ -n "$V" ] || abort "no_verdict（见 $LOG）"
echo "$V"
grep -a '#### IMAGECAP ' "$LOG" | tail -2
if grep -aq 'IMAGECAP_ABORT' "$LOG"; then echo "#### IC_VERDICT=INVALID（探针自毁，结论作废，勿据此决策）"; exit 2; fi
# 驱动归属：必须是 Mesa/rusticl，否则测的是 vendor 驱动 = 假 PASS
if ! grep -aiqE 'vendor="[^"]*(mesa|rusticl)' "$LOG"; then
  echo "#### IC_VERDICT=WRONG_DRIVER（探针加载的不是 Mesa/rusticl —— 与腿不同栈，结论作废）"; exit 2
fi
echo "$V" | grep -q 'lfm=PASS' && LFM=PASS || LFM=FAIL
echo "$V" | grep -q 'a_route=PASS' && A=PASS || A=FAIL
echo "#### IC_VERDICT lfm_image_width=$LFM a_route_subbuf=$A"
[ "$LFM" = PASS ] && [ "$A" = PASS ] && { echo "#### IC_VERDICT=GO_A_ROUTE（A 路可行，可编译 diff）"; exit 0; }
echo "#### IC_VERDICT=NO_GO（LFM 镜像宽度或子缓冲建图不可行 → A 路死刑，先谈降级再谈 diff）"; exit 1
