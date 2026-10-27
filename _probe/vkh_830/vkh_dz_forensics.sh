#!/system/bin/sh
# [vkh R-102] 暗区法证腿（终审刀）—— 全战役唯一悬案的裁决腿：4B/740 上暗区 0.878 ms/发 vs 全局
# 0.189 ms/发 的 4.6× 溢价到底归属谁（wrapper / driver / 池外 / FUSE 站内）。
#
# 单腿单口径（父令 2026-10-28）：VKH_DZ_TAG=1 + GGML_OPENCL_NDRANGE_IDLE=0（排空关掉，暗区才孤立）
# + 丙口径（--flash-attn off -ngl 99）+ --temp 0 + -v。判词**由仪表自落四档**（FUSETAX verdict=），
# 禁人算相减；addr2line 只喂同 md5 的 .so（本机 md5 必须 == EXPECT_LIB，否则 exit 6 —— 跨 build
# 抄偏移会喂出 @ :0 的假符号）。
#
# 哑火即停（R-095/R-101 教训：全绿但没测到 = 最贵的失败）：站表没起来 / dz_rows=0 / drv_sites=0
# 一律 exit 18，宁可交不出来也不交白卷。
#
# 铁律（AGENTS.md 头版）：绝不碰屏幕。stay_on_while_plugged_in 非 0 ⇒ exit 17（先归零再追查谁设的）。
# 退出码：3 无 lib · 6 lib md5 不符 · 7 热闸 · 12/13/14/15/16 txt fail-closed · 17 stayon 非 0 · 18 站表哑火
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
TAG="${TAG:-740dzf1}"
N="${N:-48}"
P="${PROMPT:-The capital of France is}"
EXPECT_LIB="${EXPECT_LIB:-959cb8591603c4520645111e7adc46bf}"   # 主战件，.debug_line 在手
TMAX="${TMAX:-440}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_HOST_TIMING=1
export GGML_OPENCL_VKH_OPTIME=1
export VKH_DZ_TAG=1                 # 暗区站表标签（默认关 = 逐字节与产品件同）
export GGML_OPENCL_NDRANGE_IDLE=0   # 排空关掉，暗区才孤立；本腿不出性能判词
mkdir -p out

# ── 腿前四闸（顺序即法：先闸后跑）───────────────────────────────────────────
SO=$(md5sum libggml-opencl.so 2>/dev/null | cut -c1-32)
echo "#### DZF_GATE1_LIB device=$SO expect=$EXPECT_LIB"
[ -n "$SO" ] || { echo "#### DZF_ABORT no lib"; exit 3; }
[ "$SO" = "$EXPECT_LIB" ] || { echo "#### DZF_ABORT lib md5 不符 ⇒ addr2line 会喂出假符号，禁跑"; exit 6; }
BAT=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9"); [ -n "$BAT" ] || BAT=0
echo "#### DZF_GATE2_TEMP batt=$BAT max=$TMAX"
[ "$BAT" -le "$TMAX" ] || { echo "#### DZF_THERMAL_ABORT 候温复"; exit 7; }
ST=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc "0-9"); [ -n "$ST" ] || ST=na
echo "#### DZF_GATE3_STAYON value=$ST"
[ "$ST" = "0" ] || { echo "#### DZF_STAYON_ABORT 屏幕常亮非 0（铁律）⇒ 先归零并追查谁设的，本腿不发"; exit 17; }
WAKE=$(dumpsys power 2>/dev/null | grep -m1 mWakefulness | tr -d ' \r'); echo "#### DZF_GATE3_WAKE $WAKE"
echo "#### DZF_BEGIN tag=$TAG lib=$SO model=$M n=$N batt=$BAT $(date +%H:%M:%S)"

./llama-cli -m "$M" -p "$P" -n "$N" --temp 0 --flash-attn off -ngl 99 -v \
    > out/dzf_${TAG}.raw 2> out/dzf_${TAG}.err
RC=$?
echo "#### DZF_RUN rc=$RC $(date +%H:%M:%S)"

E=out/dzf_${TAG}.err
# ── 阳性对照（装载证明 + 四执行指纹；全零 = 白腿，不许交）────────────────────
HT=$(grep -c "host-timing" $E 2>/dev/null)
DM=$(grep -c "DUMP called" $E 2>/dev/null); DN=$(grep -c "table=0x0 " $E 2>/dev/null)
DR=$(( ${DM:-0} - ${DN:-0} ))
OPR=$(grep -c "op=MUL_MAT" $E 2>/dev/null)
KT=$(grep "TOTAL host_ms" $E 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
echo "#### DZF_FP host_timing=${HT:-0} dumps=${DR:-0} dumps_load_sync=${DN:-0} op_rows=${OPR:-0} kernels_total=${KT:-na} rc=$RC"
if [ "${HT:-0}" -eq 0 ] || [ "${DR:-0}" -eq 0 ] || [ "${OPR:-0}" -eq 0 ] || [ "${KT:-na}" = "na" ]; then
    echo "#### DZF_ABORT 阳性对照未亮 = 仪表没上机或走了 CPU，本腿作废（不许拿白腿出判词）"; exit 5
fi

# ── 站表哑火闸：dz_rows / drv_sites 必须非零 ────────────────────────────────
STROW=$(grep "op=STATIONS" $E 2>/dev/null | tail -1)
[ -n "$STROW" ] || STROW=$(grep "STATIONS rows=" $E 2>/dev/null | tail -1)
echo "#### DZF_STATIONS $STROW"
DZR=$(printf '%s' "$STROW" | sed -n 's/.*dz_rows=\([0-9]*\).*/\1/p')
DRS=$(printf '%s' "$STROW" | sed -n 's/.*drv_sites=\([0-9]*\).*/\1/p')
if [ -z "$DZR" ] || [ "$DZR" = "0" ] || [ -z "$DRS" ] || [ "$DRS" = "0" ]; then
    echo "#### DZF_ABORT 站表哑火 dz_rows=${DZR:-none} drv_sites=${DRS:-none} ⇒ VKH_DZ_TAG 没生效或被折叠，法证腿作废"; exit 18
fi
grep "STATION_COLLAPSED" $E 2>/dev/null | tail -1 | sed 's/^/#### DZF_COLLAPSED /'

# ── 判词由仪表自落：FUSETAX 原文（禁人算相减）───────────────────────────────
grep "FUSETAX" $E 2>/dev/null | tail -3 | sed 's/^/#### DZF_FUSETAX /'
grep -c "FUSETAX" $E 2>/dev/null | sed 's/^/#### DZF_FUSETAX_LINES /'

# ── 站点分布：每个 op 取最大 host_ms 那一行（跨 dump 同站重复，取最坏档）────
tr '\r' '\n' < $E 2>/dev/null | grep -E "op=(DZ@|ENQ_DRV@|ENQ@)" | awk '
    # 注意：`host_ms=      0.2` 会被空白切成两个字段，按字段 split("=",…) 取到的永远是空串
    # ⇒ 排序键恒 0.0，top-N 退化成任意 N（第一版就这么交了白卷）。必须从整行 match 取值。
    { k=""; if (match($0,/op=[^ ]+/)) k=substr($0,RSTART+3,RLENGTH-3)
      m=0; if (match($0,/host_ms=[ ]*[0-9.]+/)) { s2=substr($0,RSTART+8,RLENGTH-8); gsub(/ /,"",s2); m=s2+0 }
      if (!(k in best) || m > best[k]) { best[k]=m; line[k]=$0 } }
    END { for (k in best) printf "%.1f|%s\n", best[k], line[k] }' 2>/dev/null | sort -t'|' -k1,1 -nr | head -14 | sed 's/^/#### DZF_SITE /'

# ── 对账：暗区 rep 的 ENQ/PRE_FORWARD vs ENQ_DRV ────────────────────────────
grep "op=ENQ\/PRE_FORWARD" $E 2>/dev/null | tail -1 | sed 's/^/#### DZF_RECON_PRE_FORWARD /'
grep "op=ENQ_DRV " $E 2>/dev/null | tail -1 | sed 's/^/#### DZF_RECON_ENQ_DRV /'
grep "op=ENQ_IDLE" $E 2>/dev/null | tail -1 | sed 's/^/#### DZF_RECON_ENQ_IDLE /'
grep "op=TOTAL" $E 2>/dev/null | tail -1 | sed 's/^/#### DZF_RECON_TOTAL /'

# ── 生成段/正文（新闸口径，fail-closed；法证腿取不到正文不算作废，只记 form）──
TXTL=$(vkh_txt_extract out/dzf_${TAG}.raw $E "$N" "$P"); TRC=$?
if [ "$TRC" -ne 0 ]; then
    echo "#### DZF_TXT rc=$TRC（法证腿不依正文 ⇒ 只记录不作废；答案口径请走队列 4）"
else
    echo "#### DZF_TXT rc=0 $TXTL"
fi
B1=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
echo "#### DZF_DONE tag=$TAG batt=${B1:-na} $(date +%H:%M:%S)"
