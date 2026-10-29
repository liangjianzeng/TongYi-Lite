#!/system/bin/sh
# [vkh R-158] LFM A路真火判卷 —— goal② 原文判据（es_base 块间互异 + 文本连贯）
# usage: sh judge_lfm.sh <tag>   (尸件在 ../chain2_1029/<tag>.tok|.err)
D=$(dirname "$0")/../chain2_1029
TAG=$1
TOK=$D/$TAG.tok; ERR=$D/$TAG.err
[ -f "$ERR" ] || { echo "VERDICT=MISSING (无 err 尸件)"; exit 1; }

# ① gate_fail 扫描（A 路三重机检六门编号；有=按门定罪）
GF=$(grep -ac 'mmid gate_fail\|view_slot' "$ERR" 2>/dev/null); GF=${GF:-0}

# ② es_base 收割：按 b_base 分组统计 distinct es_base 与非零率
LINES=$(grep -ac 'batched MoE dump' "$ERR" 2>/dev/null); LINES=${LINES:-0}
# kprobe 分型（R-161）：空发射(zero-grid) vs l4_lm 真发射算错
KP=$(grep -ac '\[kprobe\]' "$ERR" 2>/dev/null); KP=${KP:-0}
KZ=$(grep -a '\[kprobe\]' "$ERR" 2>/dev/null | grep -ac 'gw=\[0,'); KZ=${KZ:-0}
KLM=$(grep -a '\[kprobe\]' "$ERR" 2>/dev/null | grep -ac 'l4_lm'); KLM=${KLM:-0}
NZ=$(grep -a 'batched MoE dump' "$ERR" 2>/dev/null | grep -acv 'es_base=0'); NZ=${NZ:-0}
DIST=$(grep -a 'batched MoE dump' "$ERR" 2>/dev/null | grep -oE 'b_base=[0-9]+ .*es_base=[0-9]+' | sed -E 's/.*b_base=([0-9]+).*es_base=([0-9]+)/\1 \2/' | sort -u | awk '{c[$1]++} END{n=0;for(k in c){if(c[k]>1)n++};print n}')
DIST=${DIST:-0}

# ③ 文本连贯性：非空、无连续 !、含 CJK 或 ≥3 长度英文词
TOKBYTES=$(wc -c < "$TOK" 2>/dev/null); TOKBYTES=${TOKBYTES:-0}
BANGS=$(grep -ac '!!!' "$TOK" 2>/dev/null); BANGS=${BANGS:-0}
CJK=$(grep -ac '[一-龥]' "$TOK" 2>/dev/null); CJK=${CJK:-0}
if [ -f "$TOK" ]; then
  MD5=$(md5sum "$TOK" | cut -c1-8)
else
  MD5=none
fi

echo "tag=$TAG kprobe_lines=$KP zero_grid=$KZ l4lm_launches=$KLM dump_lines=$LINES es_base_nonzero=$NZ groups_multi_base=$DIST gatefail_lines=$GF tokbytes=$TOKBYTES tokmd5=$MD5 bangs=$BANGS cjk_lines=$CJK"
if [ "$LINES" -gt 0 ] && [ "$NZ" -gt 0 ] && [ "$DIST" -gt 0 ] && [ "$GF" -eq 0 ] && [ "$TOKBYTES" -gt 10 ] && [ "$BANGS" -eq 0 ]; then
  echo "VERDICT=A_ROUTE_FIRED (A路真火: es_base 块间互异+无静默降级+文本非乱)"
elif [ "$LINES" -gt 0 ] && [ "$GF" -gt 0 ]; then
  echo "VERDICT=A_ROUTE_GATED (gate_fail 按门号定罪: 看上方 view_slot* 行)"
elif [ "$LINES" -gt 0 ] && [ "$NZ" -eq 0 ]; then
  echo "VERDICT=A_ROUTE_COLD (dump 有但 es_base 恒 0 = VIEW_SLOT 未生效)"
elif [ "$KZ" -gt 0 ]; then
  echo "VERDICT=EMPTY_LAUNCH (空发射实锤:零网格 op=$KZ,R-160c35型,治本=dispatch补CPU底)"
elif [ "$KP" -gt 0 ] && [ "$KLM" -gt 0 ]; then
  echo "VERDICT=L4LM_MISCALC (l4_lm真发射仍乱/零=$KLM,R-160c37型,治本=核ne11=1特化审查)"
elif [ "$TOKBYTES" -gt 10 ] && [ "$BANGS" -eq 0 ]; then
  echo "VERDICT=TEXT_ONLY (无 dump 行,文本连贯性待人工目检)"
else
  echo "VERDICT=BAD (乱/空/炸,先看 err 尾)"
fi
