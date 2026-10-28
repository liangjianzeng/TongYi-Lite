#!/system/bin/sh
# [vkh 2026-10-28] R-094 CPU-reference contamination re-check — the "GPU 慢 7.4×" headline fuse.
#
# Why this exists: on K40 the `-ngl 0` reference leg was seen emitting 64 OpenCL instrument dumps,
# every one of them from inside graph_compute (graph_depth>0) — i.e. the "CPU" leg was still running
# graphs on the OpenCL backend. The historical 740 CPU leg swung 1.5 vs 6.7 t/s between rounds and
# carried buft GPU=980. If the reference leg is contaminated, the head verdict ("GPU is 7.4x slower
# than CPU") is measuring a hybrid, not a CPU, and must be recomputed against a clean reference.
#
# Three法定 fingerprints per arm (R-094, any non-zero on the CPU arm => ref_recalc=yes):
#   FP1 host_timing=N   count of "[host-timing]" lines   (only graph_compute prints these)
#   FP2 dumps=N         count of instrument dumps with a LIVE table (banner table!=0x0). Dumps with
#                       table=0x0 predate any vkh_op_timer, i.e. they are model-load OpenCL device
#                       syncs (buft-probe weight queries), NOT graph runs — they are reported as
#                       dumps_load_sync and never convict. closed0= graph_depth==0 (closed-window) ones.
#   FP3 kernels_last=N  the kernels= field of the last [host-timing] line (-1 = no such line at all)
#           + kernels_total=N as a second, independent source: the [vkh-optime] TOTAL row
#           + op_rows=N as a third: any timed MUL_MAT row at all (independent of both above)
#   + buft_lines=N and the last buft line verbatim (no invented parsing — the counter format is the
#     product's, so it is echoed, not reinterpreted).
#
# Discipline:
#   * The GPU arm is a POSITIVE CONTROL: it must light all three fingerprints. If it does not, the
#     greps/env/lib are wrong and a "CLEAN" on the CPU arm would be worthless -> CPUCHECK_CONTROL_FAIL
#     exit 6 before any CPU leg is even run.
#   * Proof of load (R-089) comes from the control arm: the CPU arm cannot prove its own loaded lib,
#     because "no OpenCL activity" is precisely what it is claiming.
#   * Battery gate: >440 (tenths of a degree) aborts before the next leg.
#   * Numeric gate: greedy (temp 0) completion of the CPU arm must match the GPU arm byte for byte;
#     the hash covers ONLY the completion (spinner frames track wall clock — hashing whole stdout
#     produced one false alarm already).
#   * No perf verdicts from this script and none from K40: this is mechanism, 740 owns tok/s.
#
# Run (device):  WORKDIR=/data/local/tmp/vkh_k40 MODEL=/data/local/tmp/qwen2.5-0.5b-q4_k_m.gguf \
#                TAG=k40cpu N=24 sh vkh_cpu_check.sh
# Optional:      CPU_DEVARG='--device CPU'   adds a third arm (cpu_pure) — the purified reference,
#                only when the caller supplies the arg, so this script never invents CLI behaviour.
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
TAG="${TAG:-vkhcpu}"
N="${N:-24}"
P="${PROMPT:-The capital of France is}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_VKH_OPTIME=1
export GGML_OPENCL_HOST_TIMING=1
unset GGML_OPENCL_NDRANGE_IDLE
mkdir -p out
LIBMD5=$(md5sum libggml-opencl.so 2>/dev/null | cut -c1-32)
B0=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
echo "#### CPUCHECK_HOST tag=$TAG pwd=$W lib=$LIBMD5 model=$M n=$N batt=${B0:-na} $(date +%H:%M:%S)"
[ -n "$LIBMD5" ] || { echo "#### CPUCHECK_ABORT_NO_LIB"; exit 3; }

fp_run() {                     # $1=arm  $2=ngl args  $3=extra cli args
    ARM="$1"; NG="$2"; EXTRA="$3"
    B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
    if [ -n "$B" ] && [ "$B" -gt 440 ]; then echo "#### CPUCHECK_THERMAL_ABORT arm=$ARM $B"; exit 4; fi
    echo "#### CPUCHECK_BEGIN arm=$ARM $NG $EXTRA batt=${B:-na} $(date +%H:%M:%S)"
    timeout 900 ./llama-cli -m $M $NG --flash-attn off \
        -p "$P" -n $N --temp 0 --no-display-prompt -v $EXTRA \
        > out/cc_${TAG}_${ARM}.raw 2> out/cc_${TAG}_${ARM}.err
    RC=$?
    GEN=$(tr '\r' '\n' < out/cc_${TAG}_${ARM}.raw | grep -E "Generation:" | tail -1)
    TXTL=$(vkh_txt_extract out/cc_${TAG}_${ARM}.raw out/cc_${TAG}_${ARM}.err "$N" "$P"); TXT_RC=$?
    if [ "$TXT_RC" -ne 0 ]; then echo "#### CPUCHECK_TXT_FAIL arm=$ARM rc=$TXT_RC raw=out/cc_${TAG}_${ARM}.raw — fail-closed：不落判词（R-101）"; exit 12; fi
    TXT=$(printf '%s' "$TXTL" | sed -n 's/^md5=\([0-9a-f]\{32\}\).*/\1/p')
    TXTMETA="$TXTL"
    HT=$(grep -c "host-timing" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    DM=$(grep -c "DUMP called" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    # A dump whose banner says table=0x0 was called before any vkh_op_timer had ever been
    # constructed — i.e. before any OpenCL graph_compute. Those are the model-load device syncs
    # (buft-probe asks the OpenCL backend about buffers and copies weights, which synchronizes it).
    # Counting them as contamination produced a false "CPU leg ran 64 GPU graphs" verdict on K40,
    # so only table!=0x0 dumps may convict.
    DN=$(grep -c "table=0x0 " out/cc_${TAG}_${ARM}.err 2>/dev/null)
    DR=$(( ${DM:-0} - ${DN:-0} ))
    C0=$(grep -c "graph_depth=0" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    OPR=$(grep -c "op=MUL_MAT" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    KL=$(grep "host-timing" out/cc_${TAG}_${ARM}.err 2>/dev/null | tail -1 | tr -d "\r" | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
    [ -n "$KL" ] || KL=-1
    KT=$(grep "TOTAL host_ms" out/cc_${TAG}_${ARM}.err 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
    [ -n "$KT" ] || KT=-1
    BL=$(grep -c "buft" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    # The buft-probe counters answer "could the OpenCL backend host this op", not "did it run here".
    # On the K40 `-ngl 0` arm they said -> GPU 284 / -> CPU 376 while all four EXECUTION fingerprints
    # were zero: a capability answer, not a placement. So they are context, never grounds to convict.
    BG=$(grep -c -- "-> GPU" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    BC=$(grep -c -- "-> CPU" out/cc_${TAG}_${ARM}.err 2>/dev/null)
    BV=$(grep "buft" out/cc_${TAG}_${ARM}.err 2>/dev/null | tail -1 | tr -d "\r" | cut -c1-200)
    echo "#### CPUCHECK_RESULT arm=$ARM rc=$RC | $GEN | txt=$TXT $TXTMETA"
    echo "#### CPUCHECK_FP arm=$ARM host_timing=${HT:-0} dumps=$DR closed0=${C0:-0} op_rows=${OPR:-0} kernels_last=$KL kernels_total=$KT buft_lines=${BL:-0} buft_probe_gpu=${BG:-0} buft_probe_cpu=${BC:-0} dumps_load_sync=${DN:-0}"
    echo "#### CPUCHECK_BUFT arm=$ARM $BV"
    LASTTXT="$TXT"
    [ "$RC" -eq 0 ] || { echo "#### CPUCHECK_RC_FAIL arm=$ARM rc=$RC"; exit 7; }
}

# --- positive control first: everything the fingerprints depend on must be proven alive here ---
fp_run gpu "-ngl 99" ""
if ! grep -q "vkh-optime" out/cc_${TAG}_gpu.err; then
    echo "#### CPUCHECK_PROOF_FAIL no instrument banner lib=$LIBMD5 — fingerprints would be meaningless"; exit 5
fi
GHT=$(grep -c "host-timing" out/cc_${TAG}_gpu.err 2>/dev/null)
GKL=$(grep "host-timing" out/cc_${TAG}_gpu.err 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
GDM=$(grep -c "DUMP called" out/cc_${TAG}_gpu.err 2>/dev/null)
GDN=$(grep -c "table=0x0 " out/cc_${TAG}_gpu.err 2>/dev/null)
GDR=$(( ${GDM:-0} - ${GDN:-0} ))
if [ "${GHT:-0}" -le 0 ] || [ "${GDR:-0}" -le 0 ] || [ -z "$GKL" ] || [ "$GKL" = "0" ]; then
    echo "#### CPUCHECK_CONTROL_FAIL gpu arm did not light the fingerprints (host_timing=${GHT:-0} dumps=$GDR kernels=${GKL:-na}) — do not trust any CLEAN"
    exit 6
fi
echo "#### CPUCHECK_CONTROL gpu ok host_timing=$GHT dumps=$GDR kernels=$GKL"

# --- the arm under test: exactly what the campaign ran as its CPU reference ---
fp_run cpu "-ngl 0" ""

# --- verdict ---
CHT=$(grep -c "host-timing" out/cc_${TAG}_cpu.err 2>/dev/null)
CDM=$(grep -c "DUMP called" out/cc_${TAG}_cpu.err 2>/dev/null)
CDN=$(grep -c "table=0x0 " out/cc_${TAG}_cpu.err 2>/dev/null)
CDR=$(( ${CDM:-0} - ${CDN:-0} ))
CC0=$(grep -c "graph_depth=0" out/cc_${TAG}_cpu.err 2>/dev/null)
COPR=$(grep -c "op=MUL_MAT" out/cc_${TAG}_cpu.err 2>/dev/null)
CBG=$(grep -c -- "-> GPU" out/cc_${TAG}_cpu.err 2>/dev/null)
CBC=$(grep -c -- "-> CPU" out/cc_${TAG}_cpu.err 2>/dev/null)
CKL=$(grep "host-timing" out/cc_${TAG}_cpu.err 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
CKT=$(grep "TOTAL host_ms" out/cc_${TAG}_cpu.err 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
CONTAM=no
if [ "${CHT:-0}" -gt 0 ] || [ "${CDR:-0}" -gt 0 ] || [ "${CC0:-0}" -gt 0 ] || [ "${COPR:-0}" -gt 0 ] || { [ -n "$CKL" ] && [ "$CKL" != "0" ]; } || { [ -n "$CKT" ] && [ "$CKT" != "0" ] && [ "$CKT" != "-1" ]; }; then
    CONTAM=yes
fi
if [ "$CONTAM" = "yes" ]; then
    echo "#### CPUCHECK_VERDICT arm=cpu contaminated=yes ref_recalc=yes exec_fp(host_timing=$CHT,dumps=$DR,closed0=$CC0,op_rows=$COPR) buft_probe(gpu=${CBG:-0},cpu=${CBC:-0}) — 头版「GPU 慢 N×」须按净化 CPU 参考重算（R-094）"
else
    echo "#### CPUCHECK_VERDICT arm=cpu contaminated=no ref_recalc=no exec_fp(host_timing=$CHT,dumps=$DR,closed0=$CC0,op_rows=$COPR) buft_probe(gpu=${CBG:-0},cpu=${CBC:-0}) note=执行指纹全零即纯净；buft_probe 计数是能力答复不是落地，不得单独定罪 — 头版判词数值成立"
fi

# --- optional purified reference, only when the caller supplies the CLI arg ---
if [ -n "$CPU_DEVARG" ]; then
    fp_run cpu_pure "-ngl 0" "$CPU_DEVARG"
    echo "#### CPUCHECK_VERDICT arm=cpu_pure note=净化参考腿（devarg=$CPU_DEVARG），与 cpu 腿之差即污染量级"
fi
echo "#### CPUCHECK_DONE $(date +%H:%M:%S)"
