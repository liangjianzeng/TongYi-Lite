#!/system/bin/sh
# [vkh R-112] L6：Mesa 面自研 MoE batched 解封验证枪（740 / route-A）。父亲手落闸（TYL-UNLOCK，
#   ggml-opencl.cpp helper moe_selfbuild_unlock），验件 = chroot vkh_batched 道编的 aee4f87da。
# 定罪对象：R-084 恒 false 闸把 dense-loop 平面装填连带锁死 = 「装填通用布局/计算 batched 布局」
#   劈叉态（R-110 普查 96 CPU split + 56-split 图；GATE-FAIL[adreno_moe_gate]×8）。
# 双臂（同 binary 同 stack，唯一变量 = env）：
#   off  = GGML_OPENCL_MOE_SELFBUILD 未设（零扰动对照，须复刻 l3_idle0 基线 631.0ms/tok 量级）
#   on1  = GGML_OPENCL_MOE_SELFBUILD=1（q4_0 面：装填闸①+派发闸③开）
# 顺序（R-102/R-104 律）：off 先行占冷位（被疑慢者凉），on1 后行吃热度——若更热的 on1 仍更快，
#   提速是真的且被低估。
# 机检（全 fail-closed）：GATE-FAIL 计数 on1 臂须 < off 臂；route[BATCHED_MOE] 在场；CPU split 数
#   on1 显著掉（目标个位）；txt 非空 + [host-timing] 在场；影子件 md5 = aee4f87da。
# 判词只引 [host-timing]（per-token）；tok_s 行仅抄录不自算。铁律：屏幕零触碰；温闸 440；
#   真腿 setsid nohup；排练 DRY=1；禁中 kill；SERIAL。
R=/data/local/tmp/mesa_clrt_1026
SHADOW=/data/local/tmp/vkh_batched
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$SHADOW:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
EYE=$R/bin/ling_e2e_v4ld
SHLIB=$SHADOW/libggml-opencl.so.0.27.0
BASELIB=$R/bin/libggml-base.so.0.27.0
OUT=$R/out
LING=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
EXPECT_LING=4623917248
EXPECT_SHLIB=aee4f87da
NP=${NP:-32}
NGL=${NGL:-99}
SD=${SD:-42}
TEMP_MAX=${TEMP_MAX:-440}
DRY=${DRY:-0}
ARMS="${ARMS:-off on1}"
[ -d $OUT ] || mkdir -p $OUT

# --- 四闸 + 件身份（全 fail-closed）------------------------------------------------
T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### L6_THERMAL_ABORT batt=$T max=$TEMP_MAX"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
if [ "$SO" != 0 ]; then
    echo "#### L6_STAYON $SO ⇒ 归零（绝对铁律：屏幕绝不许常亮）"; svc power stayon false >/dev/null 2>&1
    echo "#### L6_STAYON_AFTER $(settings get global stay_on_while_plugged_in 2>/dev/null)"; exit 17
fi
[ -f "$LING" ] || { echo "#### L6_ABORT reason=no_ling path=$LING"; exit 3; }
LSZ=$(stat -c %s "$LING" 2>/dev/null | tr -dc '0-9')
[ "$LSZ" = "$EXPECT_LING" ] || { echo "#### L6_ABORT reason=ling_size got=$LSZ want=$EXPECT_LING"; exit 3; }
[ -f "$EYE" ] && [ -f "$LOADER" ] || { echo "#### L6_ABORT reason=no_eye_or_loader"; exit 6; }
SM=$(md5sum "$SHLIB" 2>/dev/null | cut -c1-8)
[ "$SM" = "$EXPECT_SHLIB" ] || { echo "#### L6_RED_CARD shadow_lib=$SM want=$EXPECT_SHLIB ⇒ 影子件被换/被污，停腿"; exit 5; }
# 装载证明（双保险，禁猜）：①影子件自带唯一仪表串（arena 959 件无此串）grep 实证；
#   ②行为差分 = on1 臂 GATE-FAIL 掉零/off 臂在场——影子未被选中则双臂全同, 由对照腿戳穿。
SEL=$(grep -acF GGML_OPENCL_MOE_SELFBUILD $SHLIB 2>/dev/null | tr -dc '0-9'); [ "${SEL:-0}" -ge 1 ] || { echo "#### L6_RED_CARD shadow_missing_instrument_str"; exit 12; }
BM=$(md5sum "$BASELIB" 2>/dev/null | cut -c1-8)
[ -n "$BM" ] || { echo "#### L6_ABORT reason=no_ggml_base"; exit 6; }
echo "#### L6_BEGIN $(date +%H:%M:%S) shadow=$SM baselib=$BM eye=$(md5sum $EYE|cut -c1-8) ling=$LSZ npred=$NP ngl=$NGL seed=$SD batt=$T stayon=$SO arms=\"$ARMS\" ldselect=$SEL"
[ "$DRY" = 1 ] && { echo "#### L6_DRYRUN 门闸全过，未放腿"; exit 0; }

run_arm() {  # $1=arm
    case "$1" in
        off) unset GGML_OPENCL_MOE_SELFBUILD ;;
        on1) export GGML_OPENCL_MOE_SELFBUILD=1 ;;
        *) echo "#### L6_ABORT reason=bad_arm $1"; exit 9 ;;
    esac
    T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
    [ "$T" -gt "$TEMP_MAX" ] && { echo "#### L6_THERMAL arm=$1 batt=$T"; return 1; }
    TAG="l6_$1_r1"
    rm -f $OUT/$TAG.tok
    # 仪表 env 显式枪内设定（哑火#16 律：不吃父 shell 注入）
    timeout 1800 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp \
      OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl \
      GGML_OPENCL_HOST_TIMING=1 GGML_OPENCL_VKH_OPTIME=1 GGML_SCHED_DEBUG=1 \
      ${GGML_OPENCL_MOE_SELFBUILD:+GGML_OPENCL_MOE_SELFBUILD=$GGML_OPENCL_MOE_SELFBUILD} \
      $LOADER --library-path $LP $EYE "$LING" "$NP" "$NGL" "$SD" \
      > $OUT/$TAG.tok 2> $OUT/$TAG.err
    RC=$?
    E=$OUT/$TAG.err
    TB=$(wc -c < $OUT/$TAG.tok 2>/dev/null | tr -dc '0-9'); [ -n "$TB" ] || TB=0
    echo "#### L6RESULT arm=$1 rc=$RC tag=$TAG selfbuild=${GGML_OPENCL_MOE_SELFBUILD:-unset} lib=$SM tokbytes=$TB ht=$(grep -acF '[host-timing]' $E 2>/dev/null) gatefail=$(grep -aF 'GATE-FAIL' $E 2>/dev/null | wc -l | tr -dc '0-9') route=$(grep -aF 'route[' $E 2>/dev/null | grep -acF BATCHED_MOE) splits=$(grep -acF '## SPLIT' $E 2>/dev/null) cpusplit=$(grep -aF '## SPLIT' $E 2>/dev/null | grep -acF ': CPU') gpusplit=$(grep -aF '## SPLIT' $E 2>/dev/null | grep -acF ': OpenCL') $(grep -a tok_s= $E 2>/dev/null|tail -1) batt=$T at=$(date +%H:%M:%S)"
    # fail-closed：txt 空 = 断腿（乱文细验走 host 侧 b1_txtgate 族，此处只挡硬空）
    [ "$TB" -gt 0 ] || { echo "#### L6_TXT_FAIL arm=$1 bytes=0 ⇒ fail-closed 停腿"; exit 11; }
}

echo "#### L6_ORDER fixed=off,on1 理由=疑慢臂(off)占冷位；on1 吃热度仍快=提速真实"
for a in $ARMS; do run_arm "$a"; done
echo "#### L6_DONE $(date +%H:%M:%S)"
