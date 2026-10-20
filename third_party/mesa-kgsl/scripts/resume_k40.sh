#!/usr/bin/env bash
# [Mesa 线] K40 掉线后的恢复器（宿主侧）。机器回来一条命令收尾：等证据落盘，再决定补跑什么。
#
# 为什么需要它：设备是远程 adb，跑到一半掉线是常态（今天 K40 也掉过一次，830 掉过更久）。
# 所有取数脚本都是"先写日志/token 尺子再算数"，所以掉线不毁证据，毁的是"谁还记得哪些没跑"。
#
# 用法：SERIAL=100.67.150.120:5555 third_party/mesa-kgsl/scripts/resume_k40.sh [--rerun]
#   默认只回收 + 判读 + 报缺什么；--rerun 才把缺的队列步重新推到设备上并后台起。
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
S=${SERIAL:?设 SERIAL=<ip:5555>}
OUT=${OUT:-/tmp/mesa_ab/resume_$(date +%H%M)}
WAIT_MIN=${WAIT_MIN:-30}
mkdir -p "$OUT"

echo "== 等 $S 上线（最多 ${WAIT_MIN} 分钟）"
deadline=$(( $(date +%s) + WAIT_MIN*60 ))
while :; do
  st=$(timeout 20 adb -s "$S" get-state 2>/dev/null | tr -d '\r')
  [ "$st" = "device" ] && break
  timeout 20 adb connect "$S" >/dev/null 2>&1
  [ $(date +%s) -lt $deadline ] || { echo "!! ${WAIT_MIN} 分钟内没回来；把手机侧 adbd 重新拉起来再跑"; exit 1; }
  sleep 15
done
echo "   上线了 $(date -Iseconds) loadavg=$(timeout 20 adb -s $S shell cat /proc/loadavg 2>/dev/null | tr -d '\r')"

echo "== 回收证据到 $OUT"
timeout 60 adb -s "$S" shell 'ls -d /data/local/tmp/k40mx /data/local/tmp/p2p_* /data/local/tmp/ntab_* /data/local/tmp/p3a_* 2>/dev/null' \
  | tr -d '\r' | while read -r d; do [ -n "$d" ] && timeout 300 adb -s "$S" pull "$d" "$OUT" >/dev/null 2>&1; done
for f in k40_serial k40_matrix k40_tbo4 k40_lgd k40_ntab k40_p3a k40_press; do
  timeout 120 adb -s "$S" pull /data/local/tmp/$f.log "$OUT/$f.log" >/dev/null 2>&1
done

echo "== 离线判读"
for tokdir in "$OUT"/*/; do
  [ -d "$tokdir" ] || continue
  ls "$tokdir"/*.tok >/dev/null 2>&1 || continue
  echo "-- token_diff $tokdir"
  python3 "$ROOT/third_party/mesa-kgsl/scripts/token_diff.py" "$tokdir"/*.tok 2>&1 | tail -14
done
[ -s "$OUT/k40_matrix.log" ] && { echo "-- parse_matrix"; python3 "$ROOT/third_party/mesa-kgsl/scripts/parse_matrix.py" "$OUT/k40_matrix.log" 2>&1 | tail -20; }

echo "== 缺什么（按串行队列的次序）"
have () { [ -s "$OUT/$1" ] && grep -qa "$2" "$OUT/$1"; }
miss=""
have k40_matrix.log MATRIX_DONE      || miss="$miss matrix"
have k40_tbo4.log   TBO3_DONE        || miss="$miss tbo4"
have k40_lgd.log    LGD_DONE         || miss="$miss lgd"
have k40_ntab.log   NOTRACE_AB_DONE  || miss="$miss ntab"
have k40_p3a.log    P3_ABLATE_DONE   || miss="$miss p3_ablate"
if [ -z "$miss" ]; then echo "   全都齐了，不用补跑。"; else echo "   缺:$miss"; fi
echo
echo "补跑（把缺的步重新起在设备上）：adb -s $S shell 'setsid sh /data/local/tmp/k40_serial.sh </dev/null >/data/local/tmp/k40_serial.log 2>&1 &'"
echo "        （串行脚本会从头按序跑；已完成的步重跑不影响判读，因为每条腿的 .tok 都是独立文件名）"
