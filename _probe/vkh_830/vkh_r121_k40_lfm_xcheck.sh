#!/system/bin/sh
# vkh_r121_k40_lfm_xcheck.sh —— K40 跨机对拍腿（父令 2026-10-28 16:40）｜作者 vkh
# 目的：同模型（先核 sha256=d1c03f73）同 prompt，在 K40 复跑 740 上 SIGILL 的两手件，
#       把"740 专属（分支①）"与"模型/loader 面（分支②）"一刀切开。
# 纪律：K40 = 最低档，**只出正确性结论，绝不出性能结论**；全程不点屏（本脚本不做任何 wake/sleep，
#       更不许 stayon）；只碰我自己的序列号，740/830 归父。
#
# 宿主侧开火：
#   adb -P 15037 -s 8b1e8747 push vkh_r121_k40_lfm_xcheck.sh /data/local/tmp/
#   adb -P 15037 -s 8b1e8747 shell 'sh /data/local/tmp/vkh_r121_k40_lfm_xcheck.sh <ARM>'
# ARM:  a1 = k40allv(ALL_VARIANTS 七架构) + LFM      ← 父的主枪（对应 740 那手新 stack）
#       a2 = k40gate(单架构 libggml-cpu)   + LFM
#       a6/a7 = 同上但 ngl=6（父裁①：禁 ngl=99 全载；K40 只做可用性冒烟）
#       b1 = k40allv + ling gguf（同件换模型 ⇒ 分"件面"还是"模型面"）
#       c  = eye ling_e2e_v4ld ngl=0（B2 金标复现，md5 390044f5 那手）
#       d  = a1 + E2E_LOGITDUMP（父 740 GPU 通后直接对拍 logits）
# 可选环境变量：DRY=1（排练，不跑真枪，只出计划+闸门，必须 rc=0）
#              LFM=/path  LING=/path  NPRED=32  NGL=0  SEED=42
set -u
ARM=${1:-a1}
R=/data/local/tmp/mesa_clrt_1026
LFMD=/data/local/tmp/lfmb2
LFM=${LFM:-$LFMD/lfm2.5-24b-a2b-q4_0.gguf}
LING=${LING:-/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf}   # 父 17:49 给（4.6GB，md5 战役在案）
PF=$LFMD/p1.txt
NPRED=${NPRED:-32}; NGL=${NGL:-0}; SEED=${SEED:-42}
EXPECT_LFM=13578190880
EXPECT_SHA=d1c03f73ecaf61017d70419eec9e5dc0b05d50ae26c23d522829b934fbabf8a5
ALLV=/data/local/tmp/k40allv
GATE=/data/local/tmp/k40gate
EYE=$R/bin/ling_e2e_v4ld
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
OUT=/data/local/tmp/out_r121_${ARM}_$(date +%H%M%S).log

say() { echo "$@"; }
# ── 闸①stayon 机检（AGENTS.md 头部绝对铁律：AMOLED 烧屏不可逆；非 0 = 红牌）
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9')
[ "${SO:-0}" = "0" ] || { say "#### XK_ABORT reason=stayon_nonzero got=$SO 先查谁设的（不许常亮换在线）"; exit 4; }
# ── 闸②温（纯 I/O 档 400；perf 档不在本枪职责内）
T=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1 | tr -dc '0-9')
[ -n "$T" ] || T=0
if [ "$T" -gt 40000 ]; then say "#### XK_ABORT reason=hot temp=$T"; exit 5; fi
# ── 闸③有腿在跑就让路（ps 手比 pgrep 稳，避开 -f 自匹配）
if ps -A 2>/dev/null | grep -E "ling_e2e|llama-cli|llama-bench" | grep -v grep | grep -q .; then
  say "#### XK_ABORT reason=leg_running 有腿在跑，本枪让路"; exit 6
fi
say "#### XK_GATES stayon=$SO temp=$T arm=$ARM"

if [ "${DRY:-0}" = "1" ]; then
  say "#### XK_DRY plan arm=$ARM lfm=$LFM npred=$NPRED ngl=$NGL seed=$SEED out=$OUT"
  say "#### XK_DRY note 不跑真枪；排练态必须 rc=0"
  exit 0
fi

# ── 闸④装载证明：模型身份（父令：以 d1c03f73 为战役真值；b3463113=hf-mirror ETag 假权威已废）
[ -f "$LFM" ] || { say "#### XK_ABORT reason=no_lfm path=$LFM"; exit 3; }
SZ=$(stat -c %s "$LFM" 2>/dev/null | tr -dc '0-9')
[ "$SZ" = "$EXPECT_LFM" ] || { say "#### XK_ABORT reason=lfm_size got=$SZ want=$EXPECT_LFM"; exit 3; }
SH=$(cat "$LFMD/lfm2.5-24b-a2b-q4_0.gguf.ok" 2>/dev/null | grep -o '[0-9a-f]\{64\}' | head -1)
if [ -n "$SH" ] && [ "$SH" != "$EXPECT_SHA" ]; then
  say "#### XK_ABORT reason=lfm_sha_marker got=$SH want=$EXPECT_SHA"; exit 3
fi
say "#### XK_MODEL size=$SZ marker_sha=${SH:-none} want_sha=$EXPECT_SHA"

run_cli() {  # $1=kit dir  $2=model  $3=tag  $4=ngl(缺省=$NGL)
  local K=$1 M=$2 TAG=$3 N=${4:-$NGL} RC LOG
  [ -d "$K" ] || { say "#### XK_SKIP reason=no_kit tag=$TAG dir=$K"; return 0; }
  local BIN=$K/llama-cli
  [ -f "$BIN" ] || { say "#### XK_SKIP reason=no_bin tag=$TAG bin=$BIN"; return 0; }
  say "#### XK_BEGIN tag=$TAG kit=$(md5sum $BIN 2>/dev/null | cut -c1-8) model=$(basename $M) ngl=$N"
  logcat -c -b crash 2>/dev/null                       # 清崩溃缓冲，保证下面拿到的是本次的
  ( cd $K && LD_LIBRARY_PATH=$K TMPDIR=/data/local/tmp $BIN \
      -m "$M" -f "$PF" -ngl $N -n $NPRED --seed $SEED --temp 0 > "$OUT" 2>&1 )
  RC=$?
  say "#### XK_RUN tag=$TAG rc=$RC out=$OUT tail=$(tail -1 $OUT 2>/dev/null | cut -c1-60)"
  # ── 崩溃取证（无 root 也能拿：crash buffer 里有 DEBUG tombstone 摘要）
  if [ "$RC" -ne 0 ]; then
    say "---- XK_CRASHDUMP tag=$TAG ----"
    logcat -b crash -d -t 120 2>/dev/null | grep -iE "signal|fault addr|pc |>>> |Abort message|pid: |>>> " | head -14
    say "---- XK_CRASH_END ----"
  fi
  # ── 正确性判据：必须有非空正文（乱文/空文由父的 txtgate 逐字节判，这里只判"有没有活着出来"）
  local NB=$(wc -c < "$OUT" 2>/dev/null | tr -dc '0-9')
  say "#### XK_VERDICT tag=$TAG rc=$RC out_bytes=$NB"
}

case "$ARM" in
  a1) run_cli "$ALLV" "$LFM" "allv_lfm_ngl${NGL}" ;;
  a2) run_cli "$GATE" "$LFM" "gate_lfm_ngl${NGL}" ;;
  # 父裁①（禁 ngl=99 全载：13.578GB 权重必 resident GPU 拷贝 = bonsai2 整机 watchdog 判例，物理越线）
  # ⇒ 真火面是 ngl=6（尾部 6 层含 MoE 块×2-3 ≈ 1GB+KV）。K40 只作可用性冒烟，**不出性能结论**。
  a6) run_cli "$ALLV" "$LFM" "allv_lfm_ngl6" 6 ;;
  a7) run_cli "$GATE" "$LFM" "gate_lfm_ngl6" 6 ;;
  b1) [ -n "$LING" ] || { say "#### XK_ABORT reason=no_ling_path 用 LING=<path> 指定 ling gguf"; exit 3; }
      run_cli "$ALLV" "$LING" "allv_ling_ngl${NGL}" ;;
  c)  [ -f "$EYE" ] || { say "#### XK_ABORT reason=no_eye bin=$EYE"; exit 3; }
      say "#### XK_BEGIN tag=eye_b2 kit=$(md5sum $EYE|cut -c1-8) model=$(basename $LFM) ngl=0"
      [ -f "$LOADER" ] || { say "#### XK_ABORT reason=no_loader path=$LOADER"; exit 6; }
      ( cd $R/bin && LD_LIBRARY_PATH=$LP TMPDIR=/data/local/tmp \
          LLAMA_MOE_EXPERTS_PATH=$LFM LLAMA_MOE_LOOKAHEAD_PREFETCH=8 \
          $LOADER --library-path $LP $EYE "$LFM" $NPRED 0 $SEED ) > "$OUT" 2>&1
      RC=$?; say "#### XK_VERDICT tag=eye_b2 rc=$RC out=$(tail -1 $OUT|cut -c1-70)" ;;
  d)  [ -n "${E2E_LOGITDUMP:-}" ] || E2E_LOGITDUMP=/data/local/tmp/r121_logits_${ARM}.bin
      export E2E_LOGITDUMP
      run_cli "$ALLV" "$LFM" "allv_lfm_logitdump"
      say "#### XK_LOGITS path=$E2E_LOGITDUMP size=$(stat -c %s $E2E_LOGITDUMP 2>/dev/null)" ;;
  *) say "#### XK_ABORT reason=bad_arm arm=$ARM (a1|a2|a6|a7|b1|c|d)"; exit 2 ;;
esac
say "#### XK_DONE arm=$ARM"
exit 0
