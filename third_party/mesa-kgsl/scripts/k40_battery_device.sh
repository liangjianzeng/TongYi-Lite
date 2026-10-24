#!/system/bin/sh
# 在手机上跑的 K40/Adreno 650 工装（A6X 冒烟 + 发射预算 + 融合 + 数值契约）。
#
# 为什么整副脚本放到设备上跑：这些机器的 adbd 扛不住几十次 `adb shell` 往返（实测上线 20 秒即
# offline，八条腿全废）。主机侧只敲三次：push 本脚本、一次执行、必要时一次补取日志。
# 日志同时落盘，adbd 中途死了也已完成的腿不丢，事后单独取。
#
# 由 run_k40_bringup.sh 推送并调用；也可手工：adb shell sh /data/local/tmp/g759/k40_battery_device.sh
G=/data/local/tmp/g759
BIN=$G/e2e_instr
M=$G/Ling-3.0-tiny-Q4_0.gguf
PR='请用四段话介绍四大发明，每段不少于八十字'
TOK=${TOK:-24}
OUT=$G/k40_battery_latest.txt          # 固定名：腿是 nohup 后台跑的，主机任何时候都能单独取
RUNTS=$(date +%Y%m%d_%H%M%S)
BASE="LD_LIBRARY_PATH=$G:/vendor/lib64:/system/lib64 HOME=/data/local/tmp XDG_CACHE_HOME=/data/local/tmp E2E_NBATCH=512 E2E_SEED=42"
EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# 一次算子累计：~host/~drain 是分段不是新算子；同名取最大累计（表是累计打印的）
opsum() {
  grep -a '^\[noder\]' "$1" 2>/dev/null | grep -av '~' |
    awk '{if ($4+0>m[$2]) m[$2]=$4+0} END{s=0; for(k in m) s+=m[k]; printf "%d", s}'
}
topops() {
  grep -a '^\[noder\]' "$1" 2>/dev/null | grep -av '~' |
    awk '{n=$2; c=$4+0; if(c>m[n]) m[n]=c} END{for(k in m) printf "%.1f %s\n", m[k]/'"$TOK"', k}' |
    sort -rn | head -6 | tr '\n' ' '
}

echo "== K40 设备内工装 $(getprop ro.product.model) / $(date) ==" | tee "$OUT"
echo "ulimit -l=$(ulimit -l)  MemTotal=$(grep MemTotal /proc/meminfo | awk '{print $2}')kB" | tee -a "$OUT"

# leg 名字 ngl 额外env 温度 是否要算子数(1/0)
leg() {
  S=$1; NGL=$2; X=$3; TEMP=${4:-0.7}; NEEDOPS=${5:-1}
  L=$G/kb_${S}_$(date +%H%M%S).log
  # 注意：变量展开出来的 NAME=value 不算赋值词，会被当成"命令名"去执行（$BASE 必须走 env）
  env GGML_OPENCL_NODER_STATS=1 E2E_TEMP=$TEMP $X $BASE GGML_E2E_PROMPT="$PR" \
      timeout 1200 "$BIN" "$M" - "$NGL" "$TOK" 0 > "$L" 2>&1
  SZ=$(stat -c %s "$L" 2>/dev/null || echo 0)
  if [ "${SZ:-0}" -lt 200 ]; then
    echo "  %-12s => 作废（日志只有 ${SZ}B＝进程没起来，看下面首行）" "$S" | tee -a "$OUT"
    head -2 "$L" 2>/dev/null | cut -c1-130 | sed 's/^/      /' | tee -a "$OUT"
    return 0 2>/dev/null || return
  fi
  T=$(grep -aoE 'tok_s=[0-9.]+' "$L" | tail -1)
  O=$(grep -aoE 'offloaded [0-9]+/[0-9]+ layers' "$L" | tail -1)
  P=$(grep -aoE 'splits = [0-9]+' "$L" | tail -1)
  PL=$(grep -ac 'selected platform' "$L")
  ER=$(grep -aic 'error:' "$L")
  N=$(opsum "$L")
  printf "%-12s ngl=%-3s %-12s %-9s %-8s plat=%s err=%s ops=%s\n" "$S" "$NGL" "$T" "$P" "$O" "$PL" "$ER" "${N:-0}" | tee -a "$OUT"
  V=""
  { [ "$NEEDOPS" = 1 ] && [ "${N:-0}" -lt 1 ]; } && V="无GPU算子 "
  [ -z "$T" ] && V="$V 无tok_s"
  [ -z "$O" ] && V="$V 无offloaded"
  [ -z "$P" ] && V="$V 无splits"
  [ "${PL:-0}" -lt 1 ] && V="$V 无selected-platform"
  [ "${ER:-9}" != 0 ] && V="$V 内核err"
  if [ -n "$V" ]; then
    echo "   => 作废（$V）：$L" | tee -a "$OUT"
    grep -aiE 'unable to allocate|FATAL|kernel compile error|failed to mlock' "$L" | tail -2 |
      cut -c1-140 | sed 's/^/      死因: /' | tee -a "$OUT"
  else
    echo "   top: $(topops "$L")" | tee -a "$OUT"
  fi
}

echo "-- A. 分配墙与 ngl 阶梯（全载在 A650 会死在单块 cl_mem）--" | tee -a "$OUT"
leg NGL25 25 "GGML_OPENCL_MOE_FORCE_A7X=1"
leg NGL12 12 "GGML_OPENCL_MOE_FORCE_A7X=1"
leg CPU   0  "" 0.7 0

echo "-- B. A6X 放行自研 batched MoE（判真=不重叠地更快）--" | tee -a "$OUT"
leg MOEOFF    12 ""
leg MOEFORCE  12 "GGML_OPENCL_MOE_FORCE_A7X=1"
leg MOEOFF2   12 ""

echo "-- B2. 路由落点（GGML_OPENCL_OPFILTER，零代码）--" | tee -a "$OUT"
leg ROUTER1   12 "GGML_OPENCL_OPFILTER=ARGSORT|TOP_K|SET_ROWS|FILL|SUM_ROWS"
leg ROUTER2   12 "GGML_OPENCL_OPFILTER=ARGSORT|TOP_K|SET_ROWS|FILL|SUM_ROWS|SIGMOID"
leg ROUTER1B  12 "GGML_OPENCL_OPFILTER=ARGSORT|TOP_K|SET_ROWS|FILL|SUM_ROWS"
echo "-- C. 融合在 A6X 上是否在干活（算子数不动=没触发）--" | tee -a "$OUT"
leg FUSEOFF   12 "GGML_OPENCL_DISABLE_FUSION=1"

echo "-- D. 数值契约（贪心三腿比文本；空串指纹必须作废）--" | tee -a "$OUT"
for S in NUM_OFF NUM_FORCE NUM_CPU; do
  case $S in
    NUM_OFF)   X=""; NGLS=12;;
    NUM_FORCE) X="GGML_OPENCL_MOE_FORCE_A7X=1"; NGLS=12;;
    NUM_CPU)   X=""; NGLS=0;;
  esac
  L=$G/kn_${S}_$(date +%H%M%S).log
  env E2E_TEMP=0 $X $BASE GGML_E2E_PROMPT="$PR" timeout 1200 "$BIN" "$M" - "$NGLS" "$TOK" 0 > "$L" 2>&1
  sed -n '/prompt tokens/,/gen in/p' "$L" | tr -d '\r' | grep -av '\[' | tr -d '\n' > "$G/txt_$S.txt"
  H=$(sha256sum "$G/txt_$S.txt" | cut -c1-16)
  printf "  %-9s hash=%s  %s\n" "$S" "$H" "$(cut -c1-42 "$G/txt_$S.txt")" | tee -a "$OUT"
  if [ "$H" = "$(printf '%s' "$EMPTY_SHA256" | cut -c1-16)" ]; then
    echo "   => 作废（空串指纹＝抽取失败/adbd 掉线，绝不许当成文本一致）：$L" | tee -a "$OUT"
  fi
done
echo "DONE_K40_DEVICE_BATTERY out=$OUT ts=$RUNTS" | tee -a "$OUT"
cp "$OUT" "$G/k40_battery_$RUNTS.txt" 2>/dev/null
