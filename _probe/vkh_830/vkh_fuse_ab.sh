#!/system/bin/sh
# [vkh 2026-10-28] Price the dark zone. VKH_DZ_TAG forensics resolved every dark launch
# (ENQ/PRE_FORWARD, 490/token-run, 40 % of the submit loop with drains off) to ONE site:
# graph_compute ggml-opencl.cpp:10119 — the continuation of ggml_opencl_op_rms_norm_fused()
# at L10118. Fused helpers enqueue directly and never set g_vkh_current_op, which is exactly
# why they were dark.
#
# The product already ships an opt-out for that fuse (GGML_OPENCL_FUSE_RMS_MUL=0, L10113-10116),
# so the path can be priced without touching a byte of product code: run the same leg with the
# fuse on / off and read the dark-zone rows. Drains are pinned OFF (IDLE=0) so per-site ms is
# attribution-clean — with IDLE=2 every 2nd enqueue absorbs a full clFinish and the numbers lie.
#
# K40 = mechanism/attribution only. No perf verdict leaves this script; tok/s is printed solely
# as a sanity signal (and the numeric gate txt= must match across arms).
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
TAG="${TAG:-k40fz1}"
N="${N:-24}"
P="${PROMPT:-The capital of France is}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_VKH_OPTIME=1
export GGML_OPENCL_HOST_TIMING=1
export GGML_OPENCL_NDRANGE_IDLE=0
export VKH_DZ_TAG=1
mkdir -p out
LIBMD5=$(md5sum libggml-opencl.so 2>/dev/null | cut -c1-32)
B0=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
echo "#### FUSEAB_HOST tag=$TAG lib=$LIBMD5 n=$N batt=${B0:-na} idle=0 dz=on $(date +%H:%M:%S)"
[ -n "$LIBMD5" ] || { echo "#### FUSEAB_ABORT_NO_LIB"; exit 3; }
[ "${B0:-0}" -le 440 ] || { echo "#### FUSEAB_THERMAL_ABORT $B0"; exit 4; }

for arm in fuse_on fuse_off; do
    if [ "$arm" = "fuse_off" ]; then export GGML_OPENCL_FUSE_RMS_MUL=0; else unset GGML_OPENCL_FUSE_RMS_MUL; fi
    B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
    [ "${B:-0}" -le 440 ] || { echo "#### FUSEAB_THERMAL_ABORT arm=$arm $B"; exit 4; }
    echo "#### FUSEAB_BEGIN arm=$arm batt=$B fuse_rms_mul=${GGML_OPENCL_FUSE_RMS_MUL:-on} $(date +%H:%M:%S)"
    timeout 900 ./llama-cli -m $M -ngl 99 --flash-attn off \
        -p "$P" -n $N --temp 0 --no-display-prompt -v \
        > out/fz_${TAG}_${arm}.raw 2> out/fz_${TAG}_${arm}.err
    RC=$?
    [ "$RC" -eq 0 ] || { echo "#### FUSEAB_RC_FAIL arm=$arm rc=$RC"; exit 7; }
    grep -q "vkh-optime" out/fz_${TAG}_${arm}.err || { echo "#### FUSEAB_PROOF_FAIL arm=$arm"; exit 5; }
    GEN=$(tr '\r' '\n' < out/fz_${TAG}_${arm}.raw | grep "Generation:" | tail -1 | sed -n 's/.*Generation: \([0-9.]*\) t\/s.*/\1/p')
    TXTL=$(vkh_txt_extract out/fz_${TAG}_${arm}.raw out/fz_${TAG}_${arm}.err "$N" "$P"); TXT_RC=$?
    if [ "$TXT_RC" -ne 0 ]; then echo "#### FUSEAB_TXT_FAIL arm=$arm rc=$TXT_RC raw=out/fz_${TAG}_${arm}.raw — fail-closed：不落判词（R-101）"; exit 12; fi
    TXT=$(printf '%s' "$TXTL" | sed -n 's/^md5=\([0-9a-f]\{32\}\).*/\1/p')
    TXTMETA="$TXTL"
    AV=$(grep -c "ADDITIVITY_VIOLATION" out/fz_${TAG}_${arm}.err 2>/dev/null)
    MG=$(grep -c "MIDGRAPH_INFO" out/fz_${TAG}_${arm}.err 2>/dev/null)
    echo "#### FUSEAB_RESULT arm=$arm rc=$RC tps=${GEN:-na} txt=$TXT additivity_violations=${AV:-0} midgraph=${MG:-0}"
    E=out/fz_${TAG}_${arm}.err
    for k in LOOP_TOTAL GRAPH_TOTAL MUL_MAT "ENQ/PRE_FORWARD" ENQ_DRV ENQ_IDLE; do
        echo "#### FUSEAB_ROW arm=$arm $(grep "op=$k " $E 2>/dev/null | tail -1 | sed 's/^\[vkh-optime\] //')"
    done
    echo "#### FUSEAB_DZ arm=$arm $(grep 'STATIONS' $E 2>/dev/null | tail -1 | sed 's/.*STATIONS/STATIONS/')"
    grep "op=DZ@+0x" $E 2>/dev/null | tail -3 | sed "s/^\[vkh-optime\] /#### FUSEAB_DZROW arm=$arm /"
done
echo "#### FUSEAB_DONE $(date +%H:%M:%S)"
