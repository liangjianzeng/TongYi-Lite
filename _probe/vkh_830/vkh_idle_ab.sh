#!/system/bin/sh
# [vkh 2026-10-28] NDRANGE_IDLE A/B — the self-inflicted-drain weigh-in (K40 = mechanism only).
# Fact on the table (ggml-opencl.cpp L1456/L1459-1467 at HEAD): idle_n defaults to 2, so every
# 2nd successful NDRange enqueue calls clFinish(queue) — ~450 full-queue drains per token. That
# is a correctness fuse for the H2' race (R-060), never A/B'd for performance.
# Legs (REPS passes, alternating so thermal drift hits both arms equally):
#   idle2  default (drain every 2 launches)      — what every campaign leg has always run
#   idle0  GGML_OPENCL_NDRANGE_IDLE=0            — no drains
#   cpu    -ngl 0                                 — greedy reference for the numeric gate
# Numerical gate: the completion text of idle0 must match idle2 and the CPU reference. If IDLE=0
# produces divergent/garbage text, H2' is live: the fuse may only be made SMART, never removed —
# the perf verdict still stands, the fix is capped.
#VKH_TXT_BEGIN ─ 单一真源：四支枪必须逐字节一致（vkh_txt_selftest.sh 机检，不一致即 exit 20）
# 为什么重写（R-101 哑火案）：旧抽取器 `sed -n '/^> /{n;p}'` 假设正文在 "> " 的**下一行**。
# llama-cli 有两种形态 —— vk-rel 栈把正文印在 "> " 同一行，K40 那套栈印在下一行 —— 同行形态下
# 旧抽取器恰好跳过正文、抽到空行，于是 md5("\n")=68b329da9893e34099c7d8ad5cb9c940 一路冒充
# "逐臂逐字节相同"。**跨 build 不许互抄的不只偏移，还有输出格式假设。**
# 规范形（两种形态由此收敛到同一 md5，跨 build 才可比）：去 "> " 前缀 → 剥掉行首重复回显的 prompt
# 本体 → 丢弃空记录 → 仅裁行尾空白（代码类正文的行首缩进是内容，不许裁）。
# 用法: vkh_txt_extract RAW ERR N PROMPT      （N=0 关闭 n_gen>N 交叉；PROMPT 给 prompt 本体）
# 成功 stdout: md5=<32hex> bytes=<n> n_gen=<m> gen_rate=<x> form=<same|next>
# fail-closed 退出码：12 正文空/命中禁值(d41d8cd9=空, 68b329da=换行)/bytes<32
#                     13 n_gen 缺失或 0    14 n_gen>N(过生成)    15 Generation 速率缺失或 0
#                     16 raw 不存在
vkh_txt_extract() {
    _x_raw="$1"; _x_err="$2"; _x_n="${3:-0}"; _x_p="${4:-${PROMPT:-}}"
    # VKH_TXT_GEN_REGION=1：严格正文抽不到时退一档——把整个生成段（含 [Start thinking] 等）当指纹。
    # 用途：思考型模型把 N 烧在 thinking 段里、答案从未出现（740/4B idle1 实录），此时生成段仍是
    # 贪心解码的确定性产物，可作确定性指纹；但它**不是答案**，判词必须带 form=gen_region 标记。
    _x_g="${VKH_TXT_GEN_REGION:-0}"
    case "$_x_g" in 1|true|yes) _x_g=1 ;; *) _x_g=0 ;; esac
    case "$_x_n" in ''|*[!0-9]*) _x_n=0 ;; esac
    [ -f "$_x_raw" ] || { echo "vkh_txt: missing raw $_x_raw"; return 16; }
    _x_all=$(tr '\r' '\n' < "$_x_raw" | awk -v p="$_x_p" -v genonly="$_x_g" '
        { line = $0; sub(/[ \t]+$/, "", line) }
        !seen && line ~ /^> / {
            seen = 1
            rest = line; sub(/^> /, "", rest); sub(/^[ \t]+/, "", rest)
            if (p != "" && length(rest) > 0 && index(rest, p) == 1) {
                rest = substr(rest, length(p) + 1); sub(/^[ \t]+/, "", rest)
            }
            if (length(rest) > 0) { if (genonly) { nb++; body[nb] = rest } else same = rest }
            next
        }
        !seen { next }
        line ~ /^> ?$/ { exit }                                    # 交互提示回来 = 正文结束
        line ~ /^\[/ && !genonly { exit }                          # 严格档：thinking 段/性能行一律终止（thinking 不许冒充正文）
        line ~ /^\[ Prompt:/ { exit }                              # 生成段档：只有性能行终止
        line ~ /^(== |Exiting|print_time|eval time)/ { exit }      # 其它收尾行
        line ~ /^$/ { next }                                       # 正文不含空记录
        {
            if (!stripped && p != "" && index(line, p) == 1) {
                line = substr(line, length(p) + 1); sub(/^[ \t]+/, "", line); stripped = 1
            }
            if (length(line) > 0) { nb++; body[nb] = line }
        }
        END {
            if (nb > 0 && !genonly) { printf "FORM next\n"; for (i = 1; i <= nb; i++) print body[i] }
            else if (length(same) > 0 && !genonly) { printf "FORM same\n"; print same }
            else if (nb > 0) { printf "FORM gen_region\n"; for (i = 1; i <= nb; i++) print body[i] }
            else { printf "FORM none\n" }
        }')
    _x_form=$(printf '%s\n' "$_x_all" | head -1 | cut -d' ' -f2)
    if [ "$_x_form" = gen_region ]; then
        echo "vkh_txt: 提示 VKH_TXT_GEN_REGION=1 ⇒ 指纹取的是生成段（含 [Start thinking]），非答案正文；入册须标明" >&2
    fi
    _x_body=$(printf '%s\n' "$_x_all" | tail -n +2)
    _x_bytes=$(printf '%s' "$_x_body" | wc -c | tr -dc '0-9'); [ -n "$_x_bytes" ] || _x_bytes=0
    _x_md5=$(printf '%s' "$_x_body" | md5sum | cut -c1-32)
    case "$_x_md5" in
      d41d8cd98f00b204e9800998ecf8427e|68b329da9893e34099c7d8ad5cb9c940)
        echo "vkh_txt: 命中禁值 md5=$_x_md5（空/换行 ⇒ 抽取器又在抽空气）"; return 12 ;;
    esac
    if [ "$_x_bytes" -lt 32 ]; then echo "vkh_txt: 正文过短 bytes=$_x_bytes form=$_x_form"; return 12; fi
    _x_rate=$(tr '\r' '\n' < "$_x_raw" | grep -o 'Generation:[^|]*t/s' | tail -1 | tr -dc '0-9.')
    case "$_x_rate" in ''|0|0.0|0.00) echo "vkh_txt: Generation 速率缺失或为 0"; return 15 ;; esac
    _x_ng=
    if [ -f "$_x_err" ]; then
        _x_ng=$(tr '\r' '\n' < "$_x_err" | sed -n 's|.*eval time = *[0-9.]* ms.*/ *\([0-9][0-9]*\) tokens.*|\1|p' | tail -1)
    fi
    case "$_x_ng" in ''|*[!0-9]*) echo "vkh_txt: n_gen 不可得（err 里无 'eval time = … / N tokens'）"; return 13 ;; esac
    [ "$_x_ng" -gt 0 ] || { echo "vkh_txt: n_gen=0"; return 13; }
    if [ "$_x_n" -gt 0 ] && [ "$_x_ng" -gt "$_x_n" ]; then echo "vkh_txt: n_gen=$_x_ng > N=$_x_n（过生成，口径可疑）"; return 14; fi
    echo "md5=$_x_md5 bytes=$_x_bytes n_gen=$_x_ng gen_rate=$_x_rate form=$_x_form"
    return 0
}
#VKH_TXT_END

W="${WORKDIR:-/data/local/tmp/vkh_k40}"
M="${MODEL:-/data/local/tmp/qwen2.5-0.5b-q4_k_m.gguf}"
TAG="${TAG:-k40idle}"
REPS="${REPS:-2}"
N="${N:-48}"
# Shallow prompts (6 tokens to EOS) cannot witness the H2' garbage-text race. Pass a long
# continuation prompt via PROMPT so every arm writes 100+ tokens under greedy sampling.
P="${PROMPT:-The capital of France is}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_VKH_OPTIME=1
export GGML_OPENCL_HOST_TIMING=1
mkdir -p out
LIBMD5=$(md5sum libggml-opencl.so | cut -c1-32)
echo "#### IDLEAB_HOST $TAG pwd=$W lib=$LIBMD5 model=$M reps=$REPS n=$N $(date +%H:%M:%S)"
[ -n "$LIBMD5" ] || { echo "#### IDLEAB_ABORT_NO_LIB"; exit 3; }
rep=1
while [ "$rep" -le "$REPS" ]; do
    # 真正交替（R-102 自纠，第六例哑火）：上一版注释写着 "alternating"、代码却是固定序
    # `for leg in idle2 idle0 cpu`，于是快臂恒排在慢臂之后、恒在更高温度下被测。
    # 现奇数轮正序、偶数轮反序，并落一条 ORDER 行供事后核账。
    if [ $((rep % 2)) = 0 ]; then LEGS_ORDER="cpu idle0 idle2"; else LEGS_ORDER="idle2 idle0 cpu"; fi
    echo "#### IDLEAB_ORDER rep=$rep order=$LEGS_ORDER"
    for leg in $LEGS_ORDER; do
        case $leg in
            idle2) FA=off; NG="-ngl 99"; unset GGML_OPENCL_NDRANGE_IDLE ;;
            idle0) FA=off; NG="-ngl 99"; export GGML_OPENCL_NDRANGE_IDLE=0 ;;
            cpu)   FA=off; NG="-ngl 0";  unset GGML_OPENCL_NDRANGE_IDLE ;;
        esac
        B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
        if [ -n "$B" ] && [ "$B" -gt 440 ]; then echo "#### IDLEAB_THERMAL_ABORT rep=$rep leg=$leg $B"; exit 4; fi
        echo "#### IDLEAB_BEGIN rep=$rep leg=$leg fa=$FA $NG idle=${GGML_OPENCL_NDRANGE_IDLE:-default2} batt=$B $(date +%H:%M:%S)"
        # -p was hardcoded, which silently made the PROMPT knob a no-op (the multi-prompt numeric
        # gate would not have been exercisable). Honour $P.
        timeout 900 ./llama-cli -m $M $NG --flash-attn $FA \
            -p "$P" -n $N --temp 0 --no-display-prompt -v \
            > out/ab_${TAG}_${leg}_r$rep.raw 2> out/ab_${TAG}_${leg}_r$rep.err
        RC=$?
        GEN=$(tr '\r' '\n' < out/ab_${TAG}_${leg}_r$rep.raw | grep -E "Generation:" | tail -1)
        # Completion = the line right after the '> ' prompt echo; the spinner frames and the perf
        # line must stay out of the hash (spinner frame count tracks wall clock, so hashing the
        # whole stdout makes every run look different — that false alarm cost one rerun).
        TXTL=$(vkh_txt_extract out/ab_${TAG}_${leg}_r$rep.raw out/ab_${TAG}_${leg}_r$rep.err "$N" "$P"); TXT_RC=$?
        if [ "$TXT_RC" -ne 0 ]; then echo "#### IDLEAB_TXT_FAIL rep=$rep leg=$leg rc=$TXT_RC raw=out/ab_${TAG}_${leg}_r$rep.raw — fail-closed：不落判词（R-101）"; exit 12; fi
        TXT=$(printf '%s' "$TXTL" | sed -n 's/^md5=\([0-9a-f]\{32\}\).*/\1/p')
        TXTMETA="$TXTL"
        HT=$(grep "host-timing" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        # The table is re-dumped on every graph; take the LAST dump's rows, not the first.
        IDL=$(grep "op=ENQ_IDLE" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        DRV=$(grep "op=ENQ_DRV" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        # The row is named "ENQ/PRE_FORWARD" (the dark zone) — matching "op=PRE_FORWARD" never hit
        # it, so the dark-zone column of the A/B table silently stayed empty. Keep the full name.
        PRF=$(grep "op=ENQ/PRE_FORWARD" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        TOT=$(grep "op=TOTAL\|TOTAL host_ms" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        echo "#### IDLEAB_RESULT rep=$rep leg=$leg rc=$RC | $GEN | txt=$TXT $TXTMETA"
        echo "#### IDLEAB_HT   rep=$rep leg=$leg $HT"
        echo "#### IDLEAB_ROWS rep=$rep leg=$leg $IDL"
        echo "#### IDLEAB_ROWS rep=$rep leg=$leg $DRV"
        echo "#### IDLEAB_ROWS rep=$rep leg=$leg $PRF"
        echo "#### IDLEAB_TOT  rep=$rep leg=$leg $TOT"
        if [ "$leg" != "cpu" ] && ! grep -q "vkh-optime" out/ab_${TAG}_${leg}_r$rep.err; then
            echo "#### IDLEAB_PROOF_FAIL leg=$leg no instrument banner lib=$LIBMD5 — aborting"; exit 5
        fi
    done
    rep=$((rep+1))
done
echo "#### IDLEAB_DONE $(date +%H:%M:%S)"
