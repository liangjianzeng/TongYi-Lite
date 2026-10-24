#!/system/bin/sh
# [G-805 / G-803 纪律工具] 安静态等待器 + **跑中污染监控** —— 共享机上"跑测前先确认没别人的负载"不能靠人记得
#
# 为什么要有它（2026-10-21 三次事故）：
#   1) 00:31 起跑 G-920，第 3 腿时整机被重启（后验尸：共享机被重启，非我们所为）；
#   2) 07:52 回来时机上正跑着**别人**的 `test-backend-ops -b Vulkan0 -o MUL_MAT_ID`（CPU 时间已 21 分钟）；
#   3) 08:06 等待器放行后**对方又起了一轮** —— 放行那一刻安静 ≠ 整场安静，而且我们也在污染对方的门。
#
# 两道闸（都比"看一眼 loadavg"强）：
#   闸一（放行）：连续 QUIET_STREAK 次采样都满足 loadavg<LOAD_MAX 且 无外负载 且 temp<TEMP_MAX 才放行。
#     —— 单点 loadavg 是 1 分钟均值，别人一个 200% 单进程起测瞬间根本来不及反应。
#   闸二（跑中）：TARGET 运行期间每 MON_POLL 秒查一次外负载，一旦见到就打 $OUT/CONTAMINATED 并把现场写
#     $OUT/contamination.log。**被标记的场次一律不得当裁决数用**（R2：无主键的数不入档；这里是"主键=同场无外负载"）。
#
# 两个自己踩过的坑（都是同一类病：闸分不清被测对象与仪器自身，见网格 G-908）：
#   - 匹配整行会把启动本脚本的 `sh -c ... BIN=minicpm_e2e_dspark` 当成外负载 ⇒ 只匹配命令字段 ps -ef 的 $8；
#   - 停自己的跑测时反而要匹配整行（`sh /data/local/tmp/run_g920...` 的 $8 是 `sh`）⇒ 两处口径不同，别抄错。
#
# 用法：
#   TARGET='sh /data/local/tmp/run_g920_cpubank_ab.sh 128 3' OUT=/data/local/tmp/g920_0025 \
#   RUN=... B=... M=... E=... BIN=... COOLDOWN=90 \
#   sh /data/local/tmp/wait_quiet_then_run.sh
set -u
LOAD_MAX=${LOAD_MAX:-2}
TEMP_MAX=${TEMP_MAX:-420}
WAIT_MAX=${WAIT_MAX:-5400}
POLL=${POLL:-20}
QUIET_STREAK=${QUIET_STREAK:-4}          # 连续 4 次 × 20s = 80s 持续安静才放行
MON_POLL=${MON_POLL:-10}
FOREIGN=${FOREIGN:-'test-backend-ops|llama-cli|llama-bench|llama-perplexity|vk_gate|minicpm_e2e'}
TARGET=${TARGET:?需要 TARGET=<要执行的跑测命令>}
OUT=${OUT:-/data/local/tmp}
CLOG=$OUT/contamination.log

say () { echo "[$(date +%H:%M:%S)] $*"; }
busy_procs () {
  # 排除**自己这一支**（整棵子孙树），否则 TARGET 起的 ./minicpm_e2e_dspark 会被 FOREIGN 命中 ——
  # 2026-10-21 08:5x-09:1x 就因此把自家 12 条腿全打成污染（同一类自我误判第三次：G-908 → 本脚本 v1 → v2 监控）。
  # 注意不能只比 PPID：我们的腿是 waiter -> timeout -> minicpm，是**孙进程**。故沿祖先链求闭包。
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

say "安静态等待器：需连续 ${QUIET_STREAK} 次安静（loadavg<${LOAD_MAX} / 无外负载 / temp<${TEMP_MAX}），最长 ${WAIT_MAX}s"
t0=$(date +%s); streak=0
while :; do
  LOAD=$(cut -d' ' -f1 /proc/loadavg)
  TEMP=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  BUSY=$(busy_procs); NB=$(printf '%s' "$BUSY" | grep -ac .)
  EL=$(( $(date +%s) - t0 ))

  if [ "${LOAD%.*}" -lt "$LOAD_MAX" ] 2>/dev/null && [ "$NB" -eq 0 ] \
     && [ -n "$TEMP" ] && [ "$TEMP" -lt "$TEMP_MAX" ] 2>/dev/null; then
    streak=$((streak+1))
    say "安静 $streak/$QUIET_STREAK（loadavg=$LOAD temp=$TEMP）"
    if [ "$streak" -ge "$QUIET_STREAK" ]; then
      say "持续安静达成 —— 起跑中监控并交棒：$TARGET"
      : > "$CLOG"; rm -f "$OUT/CONTAMINATED"
      ( # 闸二：跑中监控。只打标记、不杀跑测（现场要留着看是谁、什么时候进来的）
        while :; do
          B=$(busy_procs)
          if [ -n "$B" ]; then
            { echo "[$(date +%H:%M:%S)] 外负载在场:"; printf '%s\n' "$B"; } >> "$CLOG"
            touch "$OUT/CONTAMINATED"
          fi
          sleep "$MON_POLL"
        done ) &
        MON=$!
        eval "$TARGET"; RC=$?
        kill -9 "$MON" 2>/dev/null
        if [ -f "$OUT/CONTAMINATED" ]; then
          say "!! 本场跑测期间出现过外负载（见 $CLOG）：**这些数不得当裁决数用**，安静后重跑"
          exit 7
        fi
        say "全程无外负载，数可用（rc=$RC）"
        exit "$RC"
      fi
  else
    streak=0
    say "等待中 loadavg=$LOAD temp=${TEMP:-?} 外负载=$NB 已等 ${EL}s"
    printf '%s\n' "$BUSY" | grep -a . | sed 's/^/      占用: /' | head -3
  fi

  if [ "$EL" -gt "$WAIT_MAX" ]; then
    say "!! 超时 ${WAIT_MAX}s 未达成安静：**拒绝出数**，exit 6"
    exit 6
  fi
  sleep "$POLL"
done
