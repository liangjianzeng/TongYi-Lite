#!/bin/sh
# judge1.sh <tag> — 金标判卷刀（R-140）：读 out/<tag>.tok + <tag>.err（或同目录文件），
# 判据（R-136/R-140 案）：① tok 前缀含「好的」族中文 ② tokmd5 命中金标族 ③ ARGMAX 全有限
# ④ PRE id=198（金标 prefill argmax）。输出 VERDICT=SANE|GARBLED|ZEROED|INFECTED|CRASHED。
TAG="$1"
D="${JUDGE_DIR:-/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/vkh_830/chain2_1029}"
TOK="$D/$TAG.tok"; ERR="$D/$TAG.err"
[ -f "$TOK" ] || { echo "VERDICT=CRASHED (no tok)"; exit 0; }
MD5=$(md5sum "$TOK" | cut -c1-8)
HEAD=$(head -c 60 "$TOK" | tr -d '\n')
AM=$(grep -ac 'ARGMAX' "$ERR" 2>/dev/null)
NAN=$(grep -ac 'val=nan\|val=inf' "$ERR" 2>/dev/null)
ZFULL=$(grep -ac 'zeros=157184/157184' "$ERR" 2>/dev/null)
PREID=$(grep -a 'gen=PRE' "$ERR" 2>/dev/null | grep -oE 'id=[0-9]+' | head -1 | cut -d= -f2)
FIN=$(grep -ac 'absum=[0-9]' "$ERR" 2>/dev/null)
echo "tag=$TAG tokmd5=$MD5 head=[$HEAD] argmax_lines=$AM finite_lines=$FIN nan/inf=$NAN zerosfull=$ZFULL PRE_id=$PREID"
# 无 ARGMAX 探针行不得武断 CRASHED：金标 tok 本身即最强证据（l0 案：只 pull tok）。
if [ "${AM:-0}" = "0" ]; then
  if [ "$MD5" = "06c776f0" ]; then echo "VERDICT=SANE (gold md5, no probe)"; exit 0; fi
  case "$HEAD" in
    *好的*|*中国*|*发明*) echo "VERDICT=SANE (gold text, no probe)"; exit 0;;
  esac
  [ -s "$TOK" ] || { echo "VERDICT=CRASHED (empty tok)"; exit 0; }
  echo "VERDICT=UNKNOWN (no probe, tok non-gold)"; exit 0
fi
if [ "${NAN:-0}" != "0" ]; then echo "VERDICT=INFECTED (nan/inf)"; exit 0; fi
if [ "${ZFULL:-0}" != "0" ] && [ "${ZFULL:-0}" = "${AM:-0}" ]; then echo "VERDICT=ZEROED"; exit 0; fi
case "$HEAD" in
  *好的*|*中国*|*发明*) echo "VERDICT=SANE (gold text)"; exit 0;;
esac
if [ "$MD5" = "06c776f0" ]; then echo "VERDICT=SANE (gold md5)"; exit 0; fi
if [ "$PREID" = "198" ]; then echo "VERDICT=NEAR (PRE id matches gold, decode off)"; exit 0; fi
echo "VERDICT=GARBLED (finite but wrong)"
