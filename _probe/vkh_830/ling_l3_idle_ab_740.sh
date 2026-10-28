#!/system/bin/sh
# [vkh R-109] 队列 8·L3：ling-3.0-tiny 全 GPU 卸载线的 IDLE=2 vs IDLE=0 单发对照（740 / route-A Mesa 线）。
#
# 为什么这一枪最值钱：B1 三发测到 ling GPU decode per-token host **2.5 s/token**，而 4B 侧已证
#   IDLE=2 的自伤排空税是 ×5.6。若 ling 的 2.5 s 里大部分是税，"GPU 比 CPU 每 token 路径慢"就先
#   归因到我们自己插的门铃，而不是 GPU 本体——这决定后面所有优化往哪儿投。
# 双臂正典姿势**逐字抄 _probe/vkh_830/vkh_idle_ab.sh（b5f1a043）**：
#   idle2 = **unset** GGML_OPENCL_NDRANGE_IDLE（默认每 2 次 launch 排空 = 历战腿的常态）
#   idle0 = export GGML_OPENCL_NDRANGE_IDLE=0（不排空）
# 顺序纪律（R-102/R-104 教训）：单发 A/B 里**被怀疑慢的臂放前面（更凉）**，让偏差方向反对结论——
#   若更凉的 idle2 仍被更热的 idle0 甩开，税是真的且被低估。故本枪固定 idle2 → idle0。
# L1 同场零额外腿：GGML_SCHED_DEBUG=1（字符串实证在 **libggml-base.so.0.27.0**，不在 opencl 件里）
#   ⇒ .err 里普查 `splits`，全装载的机检凭证 = decode 期 splits=1（CPU 岛=0）。
# 铁律：绝不动屏幕；腿前机检 stay_on_while_plugged_in 必须 0；温闸 440；SERIAL；禁中 kill。
# 产品码一字不碰：本枪只是把 env 与件路径钉死的发射器。
R=/data/local/tmp/mesa_clrt_1026
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
EYE=$R/bin/ling_e2e_v4ld
LIB79=$R/bin/patch79e/libggml-opencl.so.0.27.0
BASELIB=$R/bin/libggml-base.so.0.27.0
OUT=$R/out
LING=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
EXPECT_LING=4623917248
EXPECT_LIB=9cf385a2
NP=${NP:-32}
NGL=${NGL:-99}
SD=${SD:-42}
TEMP_MAX=${TEMP_MAX:-440}
DRY=${DRY:-0}
ARMS="${ARMS:-idle2 idle0}"
[ -d $OUT ] || mkdir -p $OUT

# --- 四闸 + 件身份（全 fail-closed）------------------------------------------------
T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### L3_THERMAL_ABORT batt=$T max=$TEMP_MAX"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
if [ "$SO" != 0 ]; then
    echo "#### L3_STAYON $SO ⇒ 归零（绝对铁律：屏幕绝不许常亮）"; svc power stayon false >/dev/null 2>&1
    echo "#### L3_STAYON_AFTER $(settings get global stay_on_while_plugged_in 2>/dev/null)"; exit 17
fi
[ -f "$LING" ] || { echo "#### L3_ABORT reason=no_ling path=$LING"; exit 3; }
LSZ=$(stat -c %s "$LING" 2>/dev/null | tr -dc '0-9')
[ "$LSZ" = "$EXPECT_LING" ] || { echo "#### L3_ABORT reason=ling_size got=$LSZ want=$EXPECT_LING"; exit 3; }
[ -f "$EYE" ] && [ -f "$LOADER" ] || { echo "#### L3_ABORT reason=no_eye_or_loader"; exit 6; }
LM=$(md5sum "$LIB79" 2>/dev/null | cut -c1-8)
[ "$LM" = "$EXPECT_LIB" ] || { echo "#### L3_RED_CARD lib=$LM want=$EXPECT_LIB ⇒ patch79e 件被换/被污，停腿"; exit 5; }
BM=$(md5sum "$BASELIB" 2>/dev/null | cut -c1-8)
[ -n "$BM" ] || { echo "#### L3_ABORT reason=no_ggml_base (splits 凭证载体不在)"; exit 6; }
echo "#### L3_BEGIN $(date +%H:%M:%S) lib=$LM baselib=$BM eye=$(md5sum $EYE|cut -c1-8) ling=$LSZ npred=$NP ngl=$NGL seed=$SD batt=$T stayon=$SO arms=\"$ARMS\""
echo "#### L3_SCHEDPROBE GGML_SCHED_DEBUG=$(grep -acF GGML_SCHED_DEBUG $BASELIB 2>/dev/null) splits=$(grep -acF splits $BASELIB 2>/dev/null) (字符串须>0，否则 splits 凭证不可得)"
[ "$DRY" = 1 ] && { echo "#### L3_DRYRUN 门闸全过，未放腿"; exit 0; }

run_arm() {  # $1=arm
    case "$1" in
        idle2) unset GGML_OPENCL_NDRANGE_IDLE ;;
        idle0) export GGML_OPENCL_NDRANGE_IDLE=0 ;;
        *) echo "#### L3_ABORT reason=bad_arm $1"; exit 9 ;;
    esac
    T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
    [ "$T" -gt "$TEMP_MAX" ] && { echo "#### L3_THERMAL arm=$1 batt=$T"; return 1; }
    TAG="l3_$1_r1"
    rm -f $OUT/$TAG.tok
    # 仪表 env 显式在此设定（不靠父 shell 注入 ⇒ 覆盖次序无歧义，父令"别猜"）
    timeout 1800 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp \
      OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl \
      GGML_OPENCL_HOST_TIMING=1 GGML_OPENCL_VKH_OPTIME=1 GGML_SCHED_DEBUG=1 \
      ${GGML_OPENCL_NDRANGE_IDLE:+GGML_OPENCL_NDRANGE_IDLE=$GGML_OPENCL_NDRANGE_IDLE} \
      $LOADER --library-path $LP $EYE "$LING" "$NP" "$NGL" "$SD" \
      > $OUT/$TAG.tok 2> $OUT/$TAG.err
    RC=$?
    E=$OUT/$TAG.err
    echo "#### L3RESULT arm=$1 rc=$RC tag=$TAG idle=${GGML_OPENCL_NDRANGE_IDLE:-default2} lib=$LM md5=$(md5sum $OUT/$TAG.tok 2>/dev/null|cut -c1-8) bytes=$(wc -c < $OUT/$TAG.tok 2>/dev/null|tr -dc '0-9') ht=$(grep -acF '[host-timing]' $E 2>/dev/null) idleticks=$(grep -aF '[IDLE] ticks' $E 2>/dev/null|tail -1|cut -c1-40) splits=$(grep -aci splits $E 2>/dev/null) sched=$(grep -aci 'sched' $E 2>/dev/null) gpu=$(grep -ac '> GPU' $E 2>/dev/null) cpu=$(grep -ac '> CPU' $E 2>/dev/null) optrows=$(grep -acF '[vkh-optime]' $E 2>/dev/null) drm=$(grep -acF renderD128 $E 2>/dev/null) $(grep -a tok_s= $E 2>/dev/null|tail -1) batt=$T at=$(date +%H:%M:%S)"
}

echo "#### L3_ORDER fixed=idle2,idle0 理由=疑慢臂占冷位（偏差方向反对结论）"
for a in $ARMS; do run_arm "$a"; done
echo "#### L3_DONE $(date +%H:%M:%S)"
