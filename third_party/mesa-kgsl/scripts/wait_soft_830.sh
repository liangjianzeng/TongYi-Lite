#!/system/bin/sh
# [2026-10-24 G-805 变体] 830 软安静门 —— 诊断级取数用，非裁决级。
#
# 为什么需要：830 的 loadavg 有 ~13-16 的结构性地板（内核线程 D 态：cpudmof/* 每核一条、
# g_reclaim_thread、lb:g_manager，全部 0% CPU；swap 6.7GB 常驻）。原门 loadavg<2 在这台机
# 上**永远不放行**，等 5400s 也是白等。本变体只保留真正起保护作用的判据：
#   1. 无外负载进程（与原门同一份 FOREIGN 清单 + 同一套祖先闭包防自伤）；
#   2. temp < TEMP_MAX（420）；
#   3. loadavg **稳定性**（连续 4 次采样极差 < 1.5）——绝对值在 830 上无意义，但若有人在
#      我们等待期间起负载，loadavg 会跳变，这一条仍能抓住；
#   4. CPU idle > 90%（/proc/stat 10s 差分）——比 loadavg 更接近"没有真负载"的事实。
# 跑中污染监控与原门完全相同（FOREIGN 命中即打 CONTAMINATED，该场作废）。
# 出数时日志头必须带 GATE=soft-830 标记；这些数**不得当裁决级 t/s 用**，只能做
# gen7 async 病灶有无 / 数量级判断（item C 的用途）。
set -u
LOAD_RANGE=${LOAD_RANGE:-1.5}
IDLE_MIN=${IDLE_MIN:-90}
TEMP_MAX=${TEMP_MAX:-420}
POLL=${POLL:-20}
QUIET_STREAK=${QUIET_STREAK:-4}
WAIT_MAX=${WAIT_MAX:-1800}
MON_POLL=${MON_POLL:-10}
FOREIGN=${FOREIGN:-'test-backend-ops|llama-cli|llama-bench|llama-perplexity|vk_gate|minicpm_e2e'}
TARGET=${TARGET:?需要 TARGET=<要执行的跑测命令>}
OUT=${OUT:-/data/local/tmp}
CLOG=$OUT/contamination.log

say () { echo "[$(date +%H:%M:%S)] $*"; }
busy_procs () {
  ps -ef 2>/dev/null | awk -v re="$FOREIGN" -v me="$$" '
    { pp[$2] = $3
      if ($8 ~ re) { n++; c[n] = $2 " " $8 " " $9 " " $10 " " $11 } }
    END {
      own[me] = 1; go = 1
      while (go) { go = 0
        for (p in pp) if (!(p in own) && (pp[p] in own)) { own[p] = 1; go = 1 } }
      for (i = 1; i <= n; i++) { split(c[i], a, " "); if (!(a[1] in own)) print c[i] }
    }'
}
cpu_idle_pct () {
  read _ u1 n1 s1 i1 w1 irq1 sirq1 _ < /proc/stat
  t1=$((u1+n1+s1+i1+w1+irq1+sirq1)); idle1=$((i1+w1))
  sleep 5
  read _ u2 n2 s2 i2 w2 irq2 sirq2 _ < /proc/stat
  t2=$((u2+n2+s2+i2+w2+irq2+sirq2)); idle2=$((i2+w2))
  dt=$((t2-t1)); di=$((idle2-idle1))
  [ "$dt" -gt 0 ] && echo $(( di * 100 / dt )) || echo 0
}

say "830 软安静门：GATE=soft-830（loadavg 绝对门在本机结构性失效，详见脚本头）"
say "判据：无外负载 + temp<$TEMP_MAX + loadavg 极差<$LOAD_RANGE + idle>${IDLE_MIN}%，连中 $QUIET_STREAK 次"

la_min=999; la_max=0; streak=0; waited=0
while [ "$waited" -lt "$WAIT_MAX" ]; do
  la=$(cut -d' ' -f1 /proc/loadavg)
  # 温度口径与 run_mesa_matrix.sh 头一致：电池温度（十分之一度）。thermal_zone 最大值
  # 在 830 上是 GPU SoC 侧 m°C 原始数（idle 也 51+），拿它对比 TEMP_MAX 永远不过。
  temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  temp=${temp:-0}
  foreign=$(busy_procs | head -1)
  idle=$(cpu_idle_pct)
  la_min=$(awk -v a="$la_min" -v b="$la" 'BEGIN{print (b<a)?b:a}')
  la_max=$(awk -v a="$la_max" -v b="$la" 'BEGIN{print (b>a)?b:a}')
  rng=$(awk -v a="$la_max" -v b="$la_min" 'BEGIN{printf "%.2f", a-b}')
  ok=1
  [ -n "$foreign" ] && ok=0
  [ "${temp:-0}" -gt "$TEMP_MAX" ] && ok=0
  awk -v r="$rng" -v m="$LOAD_RANGE" 'BEGIN{exit !(r<m)}' || ok=0
  [ "$idle" -lt "$IDLE_MIN" ] && ok=0
  if [ "$ok" = 1 ]; then
    streak=$((streak+1))
    [ "$streak" -ge "$QUIET_STREAK" ] && break
  else
    streak=0; la_min=999; la_max=0
  fi
  say "等待中 loadavg=$la(极差$rng) idle=${idle}% temp=${temp:-?} 外负载=${foreign:-0} 已等${waited}s"
  sleep "$POLL"; waited=$((waited+POLL+5))
done
[ "$streak" -ge "$QUIET_STREAK" ] || { say "!! 软门也未放行（${waited}s）——放弃，不出数"; exit 5; }
say "软门放行：loadavg=$(cut -d' ' -f1 /proc/loadavg) idle=$(cpu_idle_pct)% —— 开跑 TARGET"

# 跑中污染监控（与原门 v2 同源）：TARGET 运行期间每 MON_POLL 秒查外负载，
# 命中即打 CONTAMINATED + 现场进 contamination.log —— 被标记的场次不得当数据用。
rm -f "$OUT/CONTAMINATED"
sh -c "$TARGET" &
tpid=$!
( while kill -0 $tpid 2>/dev/null; do
    if [ -n "$(busy_procs | head -1)" ]; then
      date '+%F %T' >> "$OUT/CONTAMINATED"
      busy_procs >> "$OUT/CONTAMINATED"
      ps -ef >> "$CLOG" 2>/dev/null
    fi
    sleep "$MON_POLL"
  done ) &
mpid=$!
wait $tpid; rc=$?
kill $mpid 2>/dev/null
[ -f "$OUT/CONTAMINATED" ] && say "!! 本场被标记 CONTAMINATED（外负载闯入），数据作废" || say "TARGET rc=$rc，全程无外负载"
exit $rc
