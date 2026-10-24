#!/system/bin/sh
# [2026-10-24 死机事故后立规] 830 温和跑测协议 —— 单腿安全包装器（v1）
#
# 事故：10-24 傍晚在 MemAvailable=5.4GB / swap 6.7GB 已用的日常机上连跑 15 次全模型
# GPU 加载（矩阵 9 腿 + CBD 6 腿，每腿 ~34GB 专家读盘冲页缓存），第 15 次加载时把
# system_server 饿死，整机死机。老教训重演：「大模型 GPU 加载 OOM 会打死整机
# system_server」（Bonsai-2 案），且原安静门的 MemAvailable≥2GB 前置在软门里被我丢了。
#
# 本脚本 = 每一腿的强制包装器。规矩（任何一条不过就跳过该腿，不硬跑）：
#   会话级（进门前查一次）：
#     GENTLE_MEM_MIN_MB   会话 MemAvailable 下限，默认按模型估算（见下）
#     GENTLE_SWAP_MAX_MB  SwapUsed 上限，默认 4096（swap 已深 = 系统已在挣扎，别再压）
#     GENTLE_MAX_LOADS    单会话全模型加载次数上限，默认 6（本次事故是 15 次）
#   每腿级（每腿开跑前再查，不是只查会话开头）：
#     MemAvailable ≥ 模型估算需求（dense 文件 + bank×slot + 2GB 余量）
#     上一腿结束后 MemAvailable 已回到会话基线 ±1.5GB（GPU pinned 内存归还验证；
#     最多等 GENTLE_RECOVER_S=300s，超时跳过 —— KGSL wedge 的先兆就是还不回来）
#   跑中级（看门狗，全程）：
#     MemAvailable < GENTLE_KILL_MB(默认 1200) → 立即 kill 测试进程并记 LEG_KILLED_MEM
#     电池温度 > GENTLE_TEMP_KILL(44℃) → kill 并记 LEG_KILLED_TEMP
#     采样周期 5s，看门狗是保护 system_server 的最后一道网
#
# 用法（矩阵/CBD runner 的每一腿都改成这样调）：
#   GENTLE_MEM_MIN_MB=8000 NPRED=64 sh gentle_830.sh <tag> <完整命令...>
# 输出日志打 stdout（进入 session.log），退出码 = 被包装命令的退出码；
# 被看门狗杀掉时退出码 125，日志里有 LEG_KILLED_* 标记，该腿数据作废。

set -u
TAG=${1:?用法: gentle_830.sh <tag> <命令...>}
shift

RUN_DIR=${RUN_DIR:-/data/local/tmp/mesa_run}
M=${M:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf}
STATE=/data/local/tmp/gentle_state
GENTLE_MEM_MIN_MB=${GENTLE_MEM_MIN_MB:-0}          # 0 = 按模型文件估算
GENTLE_SWAP_MAX_MB=${GENTLE_SWAP_MAX_MB:-4096}
GENTLE_MAX_LOADS=${GENTLE_MAX_LOADS:-6}
GENTLE_KILL_MB=${GENTLE_KILL_MB:-1200}
GENTLE_TEMP_KILL=${GENTLE_TEMP_KILL:-440}          # 电池温度十分之一度
GENTLE_RECOVER_S=${GENTLE_RECOVER_S:-300}
GENTLE_BASELINE_FILE=$STATE/baseline_avail_kb

mem_avail_kb () { awk '/MemAvailable/{print $2}' /proc/meminfo; }
swap_used_kb () { awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo; }
batt_temp () { dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'; }

mkdir -p "$STATE"

# ---- 会话级（每会话第一次调用时落基线）----
if [ ! -f "$GENTLE_BASELINE_FILE" ]; then
  avail=$(mem_avail_kb); swp=$(swap_used_kb)
  echo $((avail/1024)) > "$GENTLE_BASELINE_FILE"
  echo "[gentle] 会话基线：MemAvailable=$((avail/1024))MB SwapUsed=$((swp/1024))MB temp=$(batt_temp)"
  # 需求估算：dense 文件大小 + 512 slot × 1.29MB + 2GB 余量（KV/compute/页缓存扰动）
  est_mb=$(( $(stat -c %s "$M" 2>/dev/null || echo 0) / 1048576 + 512 * 1351680 / 1048576 + 2048 ))
  [ "$GENTLE_MEM_MIN_MB" -eq 0 ] && GENTLE_MEM_MIN_MB=$est_mb
  echo "[gentle] 模型需求估算 ${est_mb}MB（dense+bank+余量），门槛=${GENTLE_MEM_MIN_MB}MB"
  if [ "$((avail/1024))" -lt "$GENTLE_MEM_MIN_MB" ] || [ "$((swp/1024))" -gt "$GENTLE_SWAP_MAX_MB" ]; then
    echo "[gentle] !! 会话前置不过：avail=$((avail/1024))MB < 需求=${GENTLE_MEM_MIN_MB}MB 或 swap=$((swp/1024))MB > ${GENTLE_SWAP_MAX_MB}MB —— 本会话不跑（关后台应用/重启后再来）"
    exit 4
  fi
  echo 0 > "$STATE/loads"
fi
BASELINE_MB=$(cat "$GENTLE_BASELINE_FILE" | tr -dc '0-9')

# ---- 加载次数配额 ----
LOADS=$(cat "$STATE/loads" 2>/dev/null | tr -dc '0-9'); LOADS=${LOADS:-0}
if [ "$LOADS" -ge "$GENTLE_MAX_LOADS" ]; then
  echo "[gentle] !! 配额用尽：本会话已 ${LOADS} 次全模型加载（上限 $GENTLE_MAX_LOADS）——到此为止"
  exit 4
fi

# ---- 每腿前置：内存必须回到基线附近（KGSL 归还验证）----
waited=0
while :; do
  now_mb=$(( $(mem_avail_kb) / 1024 ))
  diff=$(( now_mb - BASELINE_MB ))
  [ "$diff" -ge -1536 ] && break          # 基线 -1.5GB 以内
  [ "$waited" -ge "$GENTLE_RECOVER_S" ] && {
    echo "[gentle] !! 腿[$TAG]前置不过：MemAvailable=${now_mb}MB 距基线${BASELINE_MB}MB 差 ${diff}MB，${waited}s 未归还（KGSL wedge 先兆）—— 跳过此腿"
    exit 4; }
  sleep 10; waited=$((waited+10))
done
echo "[gentle] 腿[$TAG]前置过：avail=$(( $(mem_avail_kb)/1024 ))MB（基线${BASELINE_MB}，第 $((LOADS+1))/$GENTLE_MAX_LOADS 次加载）"

# ---- 跑中看门狗 ----
"$@" &
TPID=$!
( while kill -0 $TPID 2>/dev/null; do
    av=$(( $(mem_avail_kb) / 1024 ))
    tp=$(batt_temp); tp=${tp:-0}
    if [ "$av" -lt "$GENTLE_KILL_MB" ]; then
      echo "[gentle] !! LEG_KILLED_MEM：MemAvailable=${av}MB < ${GENTLE_KILL_MB}MB —— kill 测试进程保系统"
      kill -TERM $TPID 2>/dev/null; sleep 2; kill -KILL $TPID 2>/dev/null
      exit 125
    fi
    if [ "$tp" -gt "$GENTLE_TEMP_KILL" ]; then
      echo "[gentle] !! LEG_KILLED_TEMP：电池温度=${tp} —— kill 测试进程"
      kill -TERM $TPID 2>/dev/null; sleep 2; kill -KILL $TPID 2>/dev/null
      exit 125
    fi
    sleep 5
  done ) &
WPID=$!
wait $TPID; RC=$?
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
echo $((LOADS+1)) > "$STATE/loads"
echo "[gentle] 腿[$TAG] 结束 rc=$RC（会话累计 $((LOADS+1)) 次加载；结束后 avail=$(( $(mem_avail_kb)/1024 ))MB）"
exit $RC
