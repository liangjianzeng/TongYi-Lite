#!/usr/bin/env bash
# K40（小米 K40 / Adreno 650 = A6X，AGENTS 最低冒烟档）Ling 首跑工装 —— 主机侧驱动。
#
# 架构：整副腿在手机上跑（k40_battery_device.sh），主机只敲三次 adb。
# 原因：这些机器的 adbd 扛不住几十次 `adb shell` 往返 —— 实测上线 20 秒即 offline、八条腿全废。
# 腿日志同时落盘，adbd 中途死了也能事后单独补取。
#
# 用法：third_party/mesa-kgsl/scripts/run_k40_bringup.sh [DEV]
#   DEV 默认 100.67.150.120:5555；HOST_IP=主机 tailscale 地址（默认 100.81.83.59）
#   跳过下载模型：SKIP_MODEL=1；跳过二进制部署：SKIP_DEPLOY=1；等上线次数：UP_TRIES（默认 60）
set -uo pipefail

DEV="${1:-100.67.150.120:5555}"
HOST_IP="${HOST_IP:-100.81.83.59}"
PORT="${PORT:-8799}"
G=/data/local/tmp/g759
BIN="$G/e2e_instr"
M="$G/Ling-3.0-tiny-Q4_0.gguf"
MODEL_URL='https://modelscope.cn/api/v1/models/bartowski/Ling-3.0-tiny-GGUF/resolve/master/Ling-3.0-tiny-Q4_0.gguf'
MODEL_BYTES=4623917248
MODEL_SHA=c1a548fd60cfb5a46d6e5fd7635224dec473664c9320a656132106bf7ce23cfb
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SH() { adb -s "$DEV" shell "$@"; }

echo "== 0. 等设备上线（UP_TRIES x 20s）=="
up=0
for i in $(seq 1 "${UP_TRIES:-60}"); do
  timeout 20 adb connect "$DEV" >/dev/null 2>&1
  if [ "$(SH echo ok 2>/dev/null | tr -d '\r')" = "ok" ]; then up=1; echo "   上线（第 $i 次尝试）"; break; fi
  sleep 20
done
[ $up = 0 ] && { echo "DEVICE_DOWN：需要 USB 主机重跑 scripts\\adb-wifi.ps1（tailscale IP 可能已变，可用 tailscale status 自查 android 节点）"; exit 2; }
SH "getprop ro.product.model; getprop ro.build.version.release; cat /proc/loadavg; df -h /data | tail -1" 2>&1 | tr -d '\r' | sed 's/^/   /'
SH "mkdir -p $G" >/dev/null 2>&1

if [ "${SKIP_DEPLOY:-0}" != 1 ]; then
  echo "== 1. 部署二进制（手机侧 curl 从主机 tailscale 地址拉；adb push 大包会压垮链路）=="
  ( cd /tmp/ins && python3 -m http.server "$PORT" --bind 0.0.0.0 >/tmp/k40_http.log 2>&1 ) & SRV=$!
  sleep 2
  SH "curl -sSL --fail --retry 3 -o $BIN http://$HOST_IP:$PORT/k40_instr" >/dev/null 2>&1
  SH "curl -sSL --fail --retry 3 -o $G/libopencl_stub.so http://$HOST_IP:$PORT/k40_stub.so" >/dev/null 2>&1
  SH "chmod 755 $BIN" >/dev/null 2>&1
  kill "$SRV" >/dev/null 2>&1
  E1=$(stat -c %s /tmp/ins/k40_instr 2>/dev/null); E2=$(stat -c %s /tmp/ins/k40_stub.so 2>/dev/null)
  B1=$(SH "stat -c %s $BIN 2>/dev/null" | tr -d '\r'); B2=$(SH "stat -c %s $G/libopencl_stub.so 2>/dev/null" | tr -d '\r')
  echo "   e2e_instr=$B1（期望 $E1）  stub=$B2（期望 $E2）"
  { [ -z "$E1" ] || [ "$B1" != "$E1" ] || [ -z "$E2" ] || [ "$B2" != "$E2" ]; } && { echo "   字节数不符，终止（不许拿半截二进制出结论）"; exit 3; }
fi

if [ "${SKIP_MODEL:-0}" != 1 ]; then
  echo "== 2. 模型（手机侧自下 + 字节数与 sha256 双自证）=="
  SZ=$(SH "stat -c %s $M 2>/dev/null" | tr -d '\r')
  [ "$SZ" != "$MODEL_BYTES" ] && SH "curl -sSL --fail --retry 3 -o $M '$MODEL_URL'; echo RC=\$?" 2>&1 | tr -d '\r' | tail -1 | sed 's/^/   /'
  SZ=$(SH "stat -c %s $M 2>/dev/null" | tr -d '\r'); HS=$(SH "sha256sum $M 2>/dev/null | cut -c1-64" | tr -d '\r')
  echo "   字节=$SZ 期望=$MODEL_BYTES"; echo "   sha256=$HS"
  [ "$SZ" = "$MODEL_BYTES" ] || { echo "   模型大小不符，终止"; exit 3; }
  [ "$HS" = "$MODEL_SHA" ] || echo "   sha256 与主机那份不一致 —— 先别下结论，查是否半截"
fi

echo "== 3. 推送设备内工装（小文件用 push，稳）=="
timeout 60 adb -s "$DEV" push "$SCRIPT_DIR/k40_battery_device.sh" "$G/k40_battery_device.sh" 2>&1 | tail -1 | sed 's/^/   /'

fetch () {  # 只读结果：腿在手机里后台跑，任何时候都能取，掉线也不影响它继续
  OUT=$(SH "ls -t $G/k40_battery_latest.txt 2>/dev/null | head -1" | tr -d '\r')
  echo "   设备内日志=$OUT"
  [ -n "$OUT" ] && SH "cat $OUT" 2>&1 | tr -d '\r'
}
if [ "${FETCH_ONLY:-0}" = 1 ]; then echo "== 只取结果 =="; fetch; echo DONE_K40_BRINGUP; exit 0; fi

echo "== 4. 后台点火（nohup 脱离 adb —— 否则 adbd 一死，跑了一半的腿跟着死）=="
# 这些机器每次重连只给 20~60 秒，而九条腿要 8 分钟：点火必须 1 秒返回。
timeout 60 adb -s "$DEV" shell "cd $G; nohup sh $G/k40_battery_device.sh >/dev/null 2>&1 & echo FIRED" 2>&1 | tr -d '\r' | sed 's/^/   /'
echo "   已起飞；稍后用 FETCH_ONLY=1 再跑本脚本取结果（跑完约 8~10 分钟）"

echo "== 5. 等一会儿再取（取不到就留着，事后 FETCH_ONLY=1 再取）=="
for i in 1 2 3; do
  sleep 200
  if timeout 40 adb -s "$DEV" shell echo ok 2>/dev/null | grep -q ok; then fetch; else echo "   adbd 掉了，已完成的腿仍在手机上"; fi
  timeout 40 adb -s "$DEV" shell "grep -c DONE_K40_DEVICE_BATTERY $G/k40_battery_latest.txt 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -q '^[1-9]' && break
done
echo DONE_K40_BRINGUP
