#!/usr/bin/env bash
# [vkh R-106] b_line 输出侧 txt 闸 + "乱文三分诊"分析器（host 侧，离线；被测件产物的复算器，不上机）
#
# 为什么另写一支：R-101 的 vkh_txt_extract 假设 **llama-cli 形态**（`> ` 回显 + `[ Prompt | Generation ]`）。
# ling_e2e 这类自研 eye 的产物是裸文本 `.tok`（实录：`模式!!!!!!!!!!!…`），套 llama-cli 抽取器 = 又一次
# "跨 build 互抄输出格式假设"（R-101 根律）。本器只做三件事，全部机检、不做人眼终审：
#   ① R-101 式 fail-closed 码（空/禁值/过短/无 METRIC ⇒ 各自独立 exit 码）
#   ② 退化度量：唯一字符数、最高频字符占比、CJK/拉丁字母占比 —— 用来机器判"真乱文"
#   ③ rep 间 md5 分布（3 个 rep 互拍）⇒ 三分诊：
#        真乱文(degenerate)      = 每 rep 都退化（高频字符占比 > 阈值 或 唯一字符 <= 3）
#        抽取器旧伤              = .tok 里没内容，但 .err 里有可读正文（正文在别处 = 我们的抽取面错了）
#        nondet 但稳定复现      = md5 三 rep 互不相等，但每 rep 自身非退化且 gen 数与 METRIC 相符
# 用法： vkh_b1_txtgate.sh <out_dir> <tag_prefix> [reps]      例： vkh_b1_txtgate.sh out b19_ling 3
set -u
DIR="${1:?out_dir}"; PRE="${2:?tag_prefix}"; REPS="${3:-3}"
THRESH_HIGHFREQ="${THRESH_HIGHFREQ:-0.6}"     # 最高频字符占比 > 0.6 ⇒ 退化
MIN_BYTES="${MIN_BYTES:-16}"                  # .tok 下限（该眼正文本就不长，别拿 llama 的 32 硬套）
declare -a MD5S=() BAD=0
for i in $(seq 1 "$REPS"); do
    TOK="$DIR/${PRE}_r$i.tok"; ERR="$DIR/${PRE}_r$i.err"
    if [ ! -f "$TOK" ]; then echo "#### B1TXT tag=${PRE}_r$i rc=16 missing_tok"; MD5S+=("missing"); BAD=1; continue; fi
    BYTES=$(stat -c%s "$TOK"); MD5=$(md5sum "$TOK" | cut -c1-32)
    RC=0; NOTE=""
    case "$MD5" in d41d8cd98f00b204e9800998ecf8427e|68b329da9893e34099c7d8ad5cb9c940) RC=12; NOTE="禁值(空/换行)";; esac
    [ "$RC" = 0 ] && [ "$BYTES" -lt "$MIN_BYTES" ] && { RC=12; NOTE="过短 bytes=$BYTES"; }
    # METRIC 交叉：gen 数必须存在且 > 0（等价于 R-101 的 n_gen 闸）
    GEN=$(tr -d '\r' < "$ERR" 2>/dev/null | grep -aoE 'gen=[0-9]+' | tail -1 | tr -dc '0-9')
    TOKS=$(tr -d '\r' < "$ERR" 2>/dev/null | grep -aoE 'tok_s=[0-9.]+' | tail -1 | cut -d= -f2)
    [ "$RC" = 0 ] && { [ -z "${GEN:-}" ] || [ "$GEN" = 0 ] && { RC=13; NOTE="METRIC 无 gen"; }; }
    # 退化度量（python 算，UTF-8 安全）
    DEG=$(python3 - "$TOK" <<'PY'
import sys,collections
b=open(sys.argv[1],'rb').read()
t=b.decode('utf-8','replace')
s=t.strip()
if not s: print("empty 0 0 0"); raise SystemExit
c=collections.Counter(s); top,tn=c.most_common(1)[0]
uniq=len(c); share=tn/len(s)
alpha=sum(1 for ch in s if ch.isalpha())
cjk=sum(1 for ch in s if '\u4e00'<=ch<='\u9fff')
print(f"{'yes' if (share>float(__import__('os').environ.get('THRESH_HIGHFREQ','0.6')) or uniq<=3) else 'no'} {share:.3f} {uniq} {alpha+cjk}")
PY
)
    set -- $DEG; ISDEG=$1; FREQ=$2; UNIQ=$3; ALNUM=$4
    # 抽取器旧伤判据：.tok 空/短，但 .err 里有含 CJK 或 ≥16 个字母的正文行
    ERRBODY=no
    if [ "$RC" != 0 ] || [ "$ISDEG" = yes ]; then
        ERRBODY=$(python3 - "$ERR" <<'PY'
import sys,re
# 两版启发式都栽了：44 MB 的 kgsl/Mesa 驱动日志里"像散文"的行多得是
# （`failed to open /dev/dri/renderD128…` → `ggml_opencl: selected platform: 'rusticl'`
#   → `llama_memory_recurrent, layer 0: dev = GPUOpenCL`），越补排除表越假。
# 改**结构判据**：本眼的正文只写 stdout（= 我们捕获的 .tok）；.err 里只有 eye 自己带
# 输出标记的段落才算"正文在别处"（抽取器旧伤），其余一律 no。零猜测。
MARK=re.compile(r'^\[e2e\]\s*\[(OUT|GEN|TEXT|ANSWER|BODY)\]',re.I)
try: ls=open(sys.argv[1],encoding='utf-8',errors='replace').read().split('\n')
except Exception: print("no"); raise SystemExit
for i,l in enumerate(ls):
    if MARK.match(l.strip()):
        rest=[x.strip() for x in ls[i+1:i+6] if x.strip()]
        if any(len(x)>=2 for x in rest): print("yes"); break
else: print("no")
PY
)
    fi
    echo "#### B1TXT tag=${PRE}_r$i rc=$RC${NOTE:+ note=$NOTE} md5=$MD5 bytes=$BYTES gen=${GEN:-na} tok_s=${TOKS:-na} degenerate=$ISDEG topfreq=$FREQ uniq=$UNIQ alnum=$ALNUM err_has_body=$ERRBODY"
    MD5S+=("$MD5"); [ "$RC" != 0 ] && BAD=1
done
U=$(printf '%s\n' "${MD5S[@]}" | sort -u | wc -l)
echo "#### B1TXT_REPS tags=$REPS uniq_md5=$U md5s=${MD5S[*]}"
if [ "$BAD" != 0 ]; then V="FAIL"; elif [ "$U" = 1 ]; then V="DETERMINISTIC"; else V="NONDET"; fi
echo "#### B1TXT_VERDICT gate=$V uniq_md5=$U/3 （真乱文/抽取器旧伤 看 degenerate 与 err_has_body 两列，人眼不参与）"
[ "$BAD" = 0 ] || exit 9
