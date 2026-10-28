#!/system/bin/sh
# [vkh R-103] 队列 4 —— X4 数值闸（P0 金口的 740 侧形式要件）
#
# 六案（语料真源 = _probe/x4_corpus/x4_capture.sh 的 TABLE，逐字抄，禁另造）× GPU 双臂
#   idle2 = GGML_OPENCL_NDRANGE_IDLE 默认 2（出货形态）
#   idle0 = GGML_OPENCL_NDRANGE_IDLE=0（关排空）
# 均丙口径（--flash-attn off -ngl 99，R-088）+ --temp 0 + -c <n_ctx> + --seed <seed> + -v。
#
# 主闸：**同案 GPU 双臂 txt md5 全等**（贪心确定性）。CPU 臂只作参考，永不入主闸（R-095：
# buft_probe -> CPU 只是能力答复；GPU≠CPU 的贪心漂移另案，不得在此定罪）。
#
# 关思考（父裁 R-102 选项 1）：--chat-template-kwargs '{"enable_thinking": false}'。
#   机检：raw 与 .err 里 "Start thinking" **必须零命中**；命中即 halt（exit 19）——开关失灵时
#   thinking 会照旧吃掉 npred，旧 txt 闸会拿空正文冒充"两边一致"（R-101 的哑火就是这么来的）。
#   口径偏离（0.5B 正典时代无思考型）如实入判词，判词由父落。
#
# 铁律：屏幕零触碰；stay_on_while_plugged_in 非 0 ⇒ exit 17。每腿前复温，>440 ⇒ exit 4 停腿候凉。
# 每 token 判词只准引 [host-timing] 行（R-103 新铁律）；本腿只出 md5/tok_s，不做 op 表除法。
# 退出码：3 无 lib · 6 lib md5 不符 · 4 热闸 · 5 装载证明未亮(白腿) · 17 stayon 非 0 ·
#         19 thinking 未关(halt) · 20 无案例
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

W="${WORKDIR:-/data/local/tmp/vkh740}"
M="${MODEL:-/data/local/tmp/g759/qwen35-4b-q4km.gguf}"
TAG="${TAG:-740x4a}"
EXPECT_LIB="${EXPECT_LIB:-959cb8591603c4520645111e7adc46bf}"
TMAX="${TMAX:-440}"
ONLY="${ONLY:-}"                      # 只跑某案（首腿机检用），如 ONLY=p1_cn_classic
ARMS="${ARMS:-idle2 idle0}"           # 臂过滤；CPU 参考腿用 ARMS=cpu
CTK="${CHAT_KWARGS:-{\"enable_thinking\": false\}}"
TABLE='p1_cn_classic|32|99|42|1024|请详细介绍一下中国的四大发明，分别说明历史背景与技术要点，分四段展开。
p2_en_whyblue|48|99|42|1024|Explain in detail why the sky is blue, in three short paragraphs.
p3_math_17x23|32|99|42|1024|计算 17 乘以 23 等于多少？请给出推理过程。
p4_code_fib|48|99|42|1024|写一个 Python 函数 fib(n)，返回第 n 个斐波那契数，并给出示例调用。
p5_poetry|32|99|42|1024|用「春天」「火车」「信」三个词写一首四行诗。
p6_greatwall|64|99|42|1024|介绍一下长城的历史和建筑特点，分三段。'
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_HOST_TIMING=1
export GGML_OPENCL_VKH_OPTIME=1
mkdir -p out

SO=$(md5sum libggml-opencl.so 2>/dev/null | cut -c1-32)
echo "#### X4G_GATE1_LIB device=${SO:-none} expect=$EXPECT_LIB"
[ -n "$SO" ] || { echo "#### X4G_ABORT no lib"; exit 3; }
[ "$SO" = "$EXPECT_LIB" ] || { echo "#### X4G_ABORT lib md5 不符（跨 build 不许互抄）"; exit 6; }
ST=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc "0-9"); [ -n "$ST" ] || ST=na
echo "#### X4G_GATE2_STAYON value=$ST $(dumpsys power 2>/dev/null | grep -m1 mWakefulness | tr -d ' \r')"
[ "$ST" = "0" ] || { echo "#### X4G_STAYON_ABORT 常亮非 0（铁律）⇒ 归零并追查谁设的，本批不发"; exit 17; }
echo "#### X4G_BEGIN tag=$TAG lib=$SO model=$M arms='$ARMS' only=${ONLY:-ALL} ctk=$CTK $(date +%H:%M:%S)"

FAIL=0; NDONE=0; NPASS=0; NPAIR=0; THINK_TOTAL=0; NCASE=0
# 关键（R-104 第九例哑火）：`for row in $TABLE` 默认按 **空白** 分词，含空格的英文 prompt 会被
# 剁成一个个单词 ⇒ 本案曾拿 prompt="Explain" 跑出过 "双臂 md5 全等" 的**空转过案**。
# 故外层 for 展开时 IFS 必须只留换行；循环体内立刻恢复默认 IFS（内层 `set -- $ARMS`、
# `for leg in $ARMS_ORDER` 仍要靠空格分词）。外层列表在进入循环时已展开完毕，体内改 IFS 安全。
IFS='
'
for row in $TABLE; do
    IFS=" 	"
    ID=$(printf '%s' "$row" | cut -d'|' -f1)
    NP=$(printf '%s' "$row" | cut -d'|' -f2)
    NG=$(printf '%s' "$row" | cut -d'|' -f3)
    SD=$(printf '%s' "$row" | cut -d'|' -f4)
    NC=$(printf '%s' "$row" | cut -d'|' -f5)
    PR=$(printf '%s' "$row" | cut -d'|' -f6-)
    [ -n "$ONLY" ] && [ "$ID" != "$ONLY" ] && continue
    # 奇偶反序（R-102 修掉的"注释谎言 alternating"）：热漂对双臂都要公平
    # 奇偶反序按**案号**（R-104 自纠：上一版按 `set -- $ARMS` 的 $# 判定，$# 恒为 2 ⇒ 每案都是
    # 反序 = 固定序，等于把 R-102 刚修的"注释谎言 alternating"在新刀里又犯一遍。臂数恒定不能当轮次键。）
    NCASE=$(( NCASE + 1 ))
    set -- $ARMS
    if [ "$#" = "2" ] && [ $(( NCASE % 2 )) = 0 ]; then ARMS_ORDER="$2 $1"; else ARMS_ORDER="$ARMS"; fi
    echo "#### X4G_ORDER case=$ID npred=$NP ngl=$NG seed=$SD n_ctx=$NC order=$ARMS_ORDER"
    MD5S=""; METAS=""
    for leg in $ARMS_ORDER; do
        unset GGML_OPENCL_NDRANGE_IDLE
        case $leg in
            idle2) FA=off; NGL="-ngl 99" ;;
            idle0) FA=off; NGL="-ngl 99"; export GGML_OPENCL_NDRANGE_IDLE=0 ;;
            cpu)   FA=off; NGL="-ngl 0" ;;
            *) echo "#### X4G_SKIP unknown arm $leg"; continue ;;
        esac
        B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9"); [ -n "$B" ] || B=0
        if [ "$B" -gt "$TMAX" ]; then echo "#### X4G_THERMAL_ABORT case=$ID leg=$leg batt=$B max=$TMAX — 停腿候凉"; exit 4; fi
        ST2=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc "0-9"); [ -n "$ST2" ] || ST2=na
        [ "$ST2" = "0" ] || { echo "#### X4G_STAYON_ABORT case=$ID leg=$leg value=$ST2 — 中途有人点亮屏幕，停腿"; exit 17; }
        echo "#### X4G_LEG_BEGIN case=$ID leg=$leg fa=$FA $NGL idle=${GGML_OPENCL_NDRANGE_IDLE:-default2} batt=$B $(date +%H:%M:%S)"
        timeout 1200 ./llama-cli -m "$M" $NGL --flash-attn $FA \
            -p "$PR" -n "$NP" --temp 0 -c "$NC" --seed "$SD" --no-display-prompt \
            --chat-template-kwargs "$CTK" -v \
            > out/x4_${TAG}_${ID}_${leg}.raw 2> out/x4_${TAG}_${ID}_${leg}.err
        RC=$?
        RAW=out/x4_${TAG}_${ID}_${leg}.raw; ERR=out/x4_${TAG}_${ID}_${leg}.err
        # ── 关思考机检（父令：失灵 halt，不许硬闯）────────────────────────────
        TK=$(cat $RAW $ERR 2>/dev/null | tr '\r' '\n' | grep -c "Start thinking")
        THINK_TOTAL=$(( THINK_TOTAL + ${TK:-0} ))
        if [ "${TK:-0}" -gt 0 ]; then
            echo "#### X4G_THINKING_HALT case=$ID leg=$leg hits=$TK — enable_thinking 未生效（多半是本栈未走 jinja 会话态）⇒ 停批报父，禁硬闯"
            exit 19
        fi
        # ── 装载证明（阳性对照；白腿不许出判词）───────────────────────────────
        PO=$(grep -c "host-timing" $ERR 2>/dev/null)
        KT=$(grep "TOTAL host_ms" $ERR 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
        echo "#### X4G_PROOF case=$ID leg=$leg rc=$RC host_timing=${PO:-0} kernels_total=${KT:-na}"
        if [ "$leg" != cpu ] && { [ "${PO:-0}" -eq 0 ] || [ "${KT:-na}" = "na" ]; }; then
            echo "#### X4G_ABORT case=$ID leg=$leg 装载证明未亮 = 白腿（仪表没上机或没走 GPU），停批"; exit 5
        fi
        # 反截断闸（R-104）：双臂同截断也会"全等"，故必须机检 prompt 本体原样出现在 raw 里。
        if ! tr '\r' '\n' < $RAW 2>/dev/null | grep -qF -- "$PR"; then
            echo "#### X4G_PROMPT_FAIL case=$ID leg=$leg raw 内无 prompt 回显 ⇒ 参数被截/未送达，本案不落判词"
            FAIL=1; NDONE=$(( NDONE + 1 )); MD5S="$MD5S none"; METAS="$METAS prompt_not_echoed"; continue
        fi
        GEN=$(tr '\r' '\n' < $RAW 2>/dev/null | grep -E "Generation:" | tail -1)
        HT=$(grep "host-timing" $ERR 2>/dev/null | tail -1 | tr -s ' ')
        TXTL=$(vkh_txt_extract "$RAW" "$ERR" "$NP" "$PR"); TRC=$?
        if [ "$TRC" -ne 0 ]; then
            TXTL2=$(VKH_TXT_GEN_REGION=1 vkh_txt_extract "$RAW" "$ERR" "$NP" "$PR"); TRC2=$?
            if [ "$TRC2" -eq 0 ]; then
                echo "#### X4G_TXT_TIER case=$ID leg=$leg strict_rc=$TRC ⇒ 已退生成段档（答案未出现，入册须标 form）"
                TXTL="$TXTL2"; TRC=0
            fi
        fi
        if [ "$TRC" -ne 0 ]; then
            echo "#### X4G_TXT_FAIL case=$ID leg=$leg rc=$TRC raw=$RAW — fail-closed：本案不落判词（R-101）"
            FAIL=1; MD5S="$MD5S none"; METAS="$METAS rc=$TRC"
        else
            M1=$(printf '%s' "$TXTL" | sed -n 's/^md5=\([0-9a-f]\{32\}\).*/\1/p')
            echo "#### X4G_TXT case=$ID leg=$leg $TXTL"
            echo "#### X4G_PERF case=$ID leg=$leg $GEN | $HT"
            MD5S="$MD5S $M1"; METAS="$METAS $TXTL"
        fi
        NDONE=$(( NDONE + 1 ))
    done
    if [ "$leg" = cpu ]; then
        echo "#### X4G_REF case=$ID cpu_reference_only md5s=$MD5S（R-095：CPU 臂永不入主闸）"
        continue
    fi
    A=$(printf '%s' "$MD5S" | tr ' ' '\n' | sed -n '/./p' | head -1)
    BMD=$(printf '%s' "$MD5S" | tr ' ' '\n' | sed -n '/./p' | sed -n '2p')
    if [ -z "$BMD" ]; then
        echo "#### X4G_CASE case=$ID verdict=SKIPPED (单臂/参考腿，无臂间比较)"
    elif [ -n "$A" ] && [ "$A" = "$BMD" ]; then
        NPASS=$(( NPASS + 1 )); NPAIR=$(( NPAIR + 1 ))
        echo "#### X4G_CASE case=$ID verdict=PASS arms_pair_equal=yes md5=$A"
    else
        FAIL=1; NPAIR=$(( NPAIR + 1 ))
        echo "#### X4G_CASE case=$ID verdict=FAIL arms_pair_equal=NO md5_a=$A md5_b=$BMD — 贪心漂移候选，停案报父"
    fi
done
[ "$NDONE" -gt 0 ] || { echo "#### X4G_ABORT 零腿（ONLY/ARMS 过滤掉了全部）"; exit 20; }
if [ "$FAIL" -eq 0 ] && [ "$NPAIR" -gt 0 ] && [ "$NPASS" -eq "$NPAIR" ]; then V=YES; else V=NO; fi
B1=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
echo "#### X4G_VERDICT PASS=$V legs=$NDONE pairs_compared=$NPAIR pairs_equal=$NPASS thinking_hits=$THINK_TOTAL fail=$FAIL batt=${B1:-na} $(date +%H:%M:%S)"
[ "$V" = "YES" ] || exit 9
