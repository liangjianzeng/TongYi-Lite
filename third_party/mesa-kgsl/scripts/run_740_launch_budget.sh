#!/usr/bin/env bash
# 740 发射预算（launch budget）工装：一个设备窗口内一次跑完，缺字段即作废。
#
# 为什么需要它：Adreno 740 上 Ling decode 的代价 = 每 token 的 kernel 提交次数 x 驱动每次提交往返(~400us)。
# 所以要同时录 ①算子次数 ②tok_s ③splits ④selected platform ⑤offloaded，只看 tok_s 会误判。
# 740 的 adbd 一天掉三次，窗口极短 => 全部塞进一个脚本，进去就全跑完。
#
# 用法：
#   third_party/mesa-kgsl/scripts/run_740_launch_budget.sh [DEV]
#   DEV 默认 100.109.138.2:5555（小米13 / Adreno 740，AGENTS 机型分级的主力+底线档）
#   可用环境变量覆盖：BIN（设备上的仪器构建）、M（模型绝对路径）、TOK（生成 token 数）、TOKEN_MIN（作废阈值）
set -uo pipefail

DEV="${1:-100.109.138.2:5555}"
G=/data/local/tmp/g759
BIN="${BIN:-$G/e2e_instr}"                 # 必须带 noder 插桩（HEAD + SSM 修复 + per-op 计时）
M="${M:-$G/Ling-3.0-tiny-Q4_0.gguf}"
TOK="${TOK:-24}"
NGL="${NGL:-25}"
PR='请用四段话介绍四大发明，每段不少于八十字'
P="LD_LIBRARY_PATH=$G:/vendor/lib64:/system/lib64 TONGYILITE_STUB_VERBOSE=1 HOME=/data/local/tmp XDG_CACHE_HOME=/data/local/tmp E2E_NBATCH=512 E2E_NOMMAP=1 E2E_SEED=42 E2E_TEMP=0.7"
MOE_APP="LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1"

echo "== 等设备上线（最多 10 次 x 20s）=="
up=0
for i in $(seq 1 10); do
  timeout 20 adb connect "$DEV" >/dev/null 2>&1
  if [ "$(adb -s "$DEV" shell echo ok 2>/dev/null | tr -d '\r')" = "ok" ]; then up=1; echo "   上线（第 $i 次）"; break; fi
  sleep 20
done
[ $up = 0 ] && { echo "DEVICE_DOWN：需要 USB 主机跑 scripts\\adb-wifi.ps1 重新 adb tcpip 5555"; exit 2; }

# 从 noder 表算"每 token 提交次数"：同名列取最大累计（表是累计打印的），~host/~drain 是分段不是新算子
opsum() {
  adb -s "$DEV" shell "grep -a '^\[noder\]' $1 | grep -av '~' | awk '{if (\$4+0>m[\$2]) m[\$2]=\$4+0} END{s=0; for(k in m) s+=m[k]; printf \"%d\", s}'" 2>/dev/null | tr -d '\r'
}
topops() {
  adb -s "$DEV" shell "grep -a '^\[noder\]' $1 | grep -av '~'" 2>/dev/null | tr -d '\r' \
    | awk '{n=$2; c=$4+0; if(c>m[n]) m[n]=c} END{for(k in m) printf "%.1f %s\n", m[k]/'"$TOK"', k}' | sort -rn | head -8 | tr '\n' ' '
}

leg() {  # leg 名字 额外env [ngl]
  local seq="$1" x="$2" ngl="${3:-$NGL}"
  local log="$G/lb740_${seq}_$(date +%H%M%S).log"
  adb -s "$DEV" shell "GGML_OPENCL_NODER_STATS=1 GGML_OPENCL_MOE_FORCE_A7X=1 $x $P GGML_E2E_PROMPT='$PR' timeout 1800 $BIN '$M' - $ngl $TOK 0 > $log 2>&1" >/dev/null
  local n t s o pl
  n=$(opsum "$log"); t=$(adb -s "$DEV" shell "grep -aoE 'tok_s=[0-9.]+' $log | tail -1" | tr -d '\r')
  s=$(adb -s "$DEV" shell "grep -aoE 'splits = [0-9]+' $log | tail -1" | tr -d '\r')
  o=$(adb -s "$DEV" shell "grep -aoE 'offloaded [0-9]+/[0-9]+ layers' $log | tail -1" | tr -d '\r')
  pl=$(adb -s "$DEV" shell "grep -ac 'selected platform' $log" | tr -d '\r')
  local per; per=$(awk -v n="${n:-0}" -v t="$TOK" 'BEGIN{printf "%.0f", n/t}')
  printf "%-12s ops/tok=%-6s %-11s %-9s %-8s plat=%s\n" "$seq" "${per:-0}" "$t" "$s" "$o" "$pl"
  # R8(h)：结构字段缺任一项，这条腿作废（CPU 参照腿 ngl=0 没有 GPU 算子，不许拿 ops 作废它）
  if { [ "${ngl}" != "0" ] && [ "${per:-0}" -lt 1 ]; } || [ -z "$t" ] || [ -z "$s" ] || [ -z "$o" ] || [ "${pl:-0}" -lt 1 ]; then
    echo "   => 作废（R8(h) 结构字段不全）：$log"
    adb -s "$DEV" shell "grep -aiE 'unable to allocate|FATAL|kernel compile error|failed to mlock' $log | tail -2" 2>&1 | tr -d '\r' | cut -c1-150 | sed 's/^/      死因: /'
  else
    echo "   top: $(topops "$log")"
  fi
}

echo "== A. 发射预算主表（同一仪器构建，只有 env 在变）=="
leg BASE        ""
leg APPMOE      "$MOE_APP"
leg MOEOFF      "LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=0 LLAMA_MOE_LOOKAHEAD_PREFETCH=0 LLAMA_MOE_DECODE_WINDOW=0 LLAMA_MOE_IO_THREADS=0"
leg BASE2       ""
echo "== B0. 路由落点实验 G-782（现成的 GGML_OPENCL_OPFILTER，零代码、零重编）=="
# 这些是 decode 时每层 ~128 float 的小算子（§20.46 点算 = 18 次/层）；GET_ROWS 不许进过滤器：
# 它同时是 embedding gather，按算子名分不清大小，误伤就变成一次大拷贝（这正是最终要按尺寸判定的理由）。
leg ROUTER1   "GGML_OPENCL_OPFILTER=ARGSORT|TOP_K|SET_ROWS|FILL|SUM_ROWS"
leg ROUTER2   "GGML_OPENCL_OPFILTER=ARGSORT|TOP_K|SET_ROWS|FILL|SUM_ROWS|SIGMOID"
leg ROUTER1B  "GGML_OPENCL_OPFILTER=ARGSORT|TOP_K|SET_ROWS|FILL|SUM_ROWS"
echo "== B. 融合是否真在干活（算子数不动=没触发）=="
leg FUSE_ALL_OFF "GGML_OPENCL_DISABLE_FUSION=1"
leg FUSE_RMSMUL  "GGML_OPENCL_FUSE_RMS_MUL=0"
leg FUSE_MOECOMB "GGML_OPENCL_FUSE_MOE_COMBINE=0"
echo "== C. CPU 后端参照（740 上 GPU 必须压过它才算赢，AGENTS 底线档口径）=="
leg CPUONLY     "" 0
echo "== D. App 侧复验（你自己点，我抓引擎日志）=="
echo "   先清缓冲：adb -s $DEV logcat -c"
echo "   在 App 里用 Ling 发一条，然后："
echo "   adb -s $DEV logcat -d | grep -aE 'handleLoadModel|selected platform|offloaded|splits =|sched_reserve|tok' | tail -30"
echo "DONE_740_LAUNCH_BUDGET"
