#!/system/bin/sh
# [vkh R-108] B2 CPU 金标腿（K40 / Snapdragon 870 / Adreno 650，**正确性轨，不出性能结论**）。
#
# 目的：给 route-A 的 `b29_lfm_n*` 案对拍用一把 CPU 金标尺（那批 GPU 腿全死于
#   `layer 2 requires more than 8 unique experts in one graph` ⇒ tok_bytes=0，没有可比正文）。
# 口径（逐字对齐正典 _probe/mesa_legs/routeA_1026/b_line_740.sh 的 b29_lfm 腿）：
#   npred=32 / seed=42 / MOEENV 同串（SLOT_BANK=32 等），**ngl=0 = CPU 岛**；
#   另加一档 x4 六案正典 p1_cn_classic @npred=64 作跨案尺子（父裁）。
#   npred=32 不是我从 ling 案借的：同批 CPU 腿 b2_cpu 的 .err 自报 `gen=32` 有件可证。
# 件纪律：LP **故意不含 patch79e** ⇒ soname 只能落金库 2695a8be；md5 红卡，金库一字不许动。
# 铁律：绝不动屏幕（无 svc power / 无 KEYCODE_*）；腿前机检 stay_on_while_plugged_in 必须 0。
# 用法（host 侧）：adb -P 15037 -s 8b1e8747 shell setsid nohup env GOLD_SHA_OK=1 sh b2_cpu_gold_k40.sh </dev/null >out 2>&1 &
R=/data/local/tmp/mesa_clrt_1026
LFMD=/data/local/tmp/lfmb2
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
LIB=$R/bin/libggml-opencl.so.0.27.0
EYE=$R/bin/ling_e2e_v4ld
OUT=$R/out
LFM=$LFMD/lfm2.5-24b-a2b-q4_0.gguf
P1F=$LFMD/p1.txt
EXPECT_LFM=13578190880
GOLD_LIB=2695a8be
TEMP_MAX=${TEMP_MAX:-440}
[ -d $OUT ] || mkdir -p $OUT
[ -d $LFMD ] || { echo "#### B2G_ABORT reason=no_lfmb2_dir"; exit 3; }

# --- 四闸 --------------------------------------------------------------------
T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### B2G_THERMAL_ABORT batt=$T max=$TEMP_MAX"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
if [ "$SO" != 0 ]; then
    echo "#### B2G_STAYON $SO ⇒ 归零（绝对铁律：屏幕绝不许常亮）"
    svc power stayon false >/dev/null 2>&1
    echo "#### B2G_STAYON_AFTER $(settings get global stay_on_while_plugged_in 2>/dev/null)"
    exit 17
fi
[ "${GOLD_SHA_OK:-0}" = 1 ] || { echo "#### B2G_ABORT reason=sha_not_certified (先过 push 枪的源站 sha256 闸再喂 B2)"; exit 18; }
[ -f "$LFM" ] || { echo "#### B2G_ABORT reason=no_lfm"; exit 3; }
SZ=$(stat -c %s "$LFM" 2>/dev/null | tr -dc '0-9')
[ "$SZ" = "$EXPECT_LFM" ] || { echo "#### B2G_ABORT reason=lfm_size got=$SZ want=$EXPECT_LFM"; exit 3; }
LIBM=$(md5sum "$LIB" 2>/dev/null | cut -c1-8)
[ "$LIBM" = "$GOLD_LIB" ] || { echo "#### B2G_RED_CARD lib=$LIBM want=$GOLD_LIB ⇒ 金库件被换/被污，停腿"; exit 5; }
[ -f "$LOADER" ] && [ -f "$EYE" ] || { echo "#### B2G_ABORT reason=no_loader_or_eye"; exit 6; }
P1P=$(cat "$P1F" 2>/dev/null)
[ -n "$P1P" ] || { echo "#### B2G_ABORT reason=no_p1_prompt_file（走 adb push 落盘，不许 shell 里塞中文）"; exit 19; }
# 哑火 #15 的教训：抽取器曾把 nc=1024 当正文（字段索引错），这里加"正文过短/纯数字即拒"的结构闸。
P1B=$(printf %s "$P1P" | wc -c | tr -dc '0-9')
[ "$P1B" -ge 20 ] || { echo "#### B2G_ABORT reason=p1_too_short bytes=$P1B ⇒ 抽取器取错字段，停腿"; exit 19; }
case "$P1P" in (*[!0-9]*) ;; (*) echo "#### B2G_ABORT reason=p1_all_digits ⇒ 取到的是数字字段不是正文"; exit 19;; esac
echo "#### B2G_BEGIN $(date +%H:%M:%S) lib=$LIBM eye=$(md5sum $EYE|cut -c1-8) lfm_bytes=$SZ batt=$T stayon=$SO"
echo "#### B2G_P1 bytes=$(printf %s "$P1P" | wc -c | tr -dc '0-9') md5=$(printf %s "$P1P" | md5sum | cut -c1-32)"

run_eye() {  # $1=tag $2=npred $3=ngl $4=prompt(可空)
    if [ "$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')" -gt "$TEMP_MAX" ]; then
        echo "#### B2G_THERMAL $1 at=$(date +%H:%M:%S)"; return 1
    fi
    rm -f $OUT/$1.tok
    if [ -n "$4" ]; then
        timeout 1800 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp \
          OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl \
          LLAMA_MOE_EXPERTS_PATH=$LFM LLAMA_MOE_SLOT_BANK=32 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 \
          LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_PREFETCH_READ=6 E2E_NB=16 \
          $LOADER --library-path $LP $EYE "$LFM" "$2" "$3" 42 "$4" \
          > $OUT/$1.tok 2> $OUT/$1.err
    else
        timeout 1800 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp \
          OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl \
          LLAMA_MOE_EXPERTS_PATH=$LFM LLAMA_MOE_SLOT_BANK=32 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 \
          LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_PREFETCH_READ=6 E2E_NB=16 \
          $LOADER --library-path $LP $EYE "$LFM" "$2" "$3" 42 \
          > $OUT/$1.tok 2> $OUT/$1.err
    fi
    RC=$?
    echo "#### B2GRESULT tag=$1 rc=$RC npred=$2 ngl=$3 lib=$LIBM md5=$(md5sum $OUT/$1.tok 2>/dev/null|cut -c1-8) bytes=$(wc -c < $OUT/$1.tok 2>/dev/null | tr -dc '0-9') gpu=$(grep -ac '> GPU' $OUT/$1.err 2>/dev/null) cpu=$(grep -ac '> CPU' $OUT/$1.err 2>/dev/null) vkh=$(grep -aic vkh $OUT/$1.err 2>/dev/null) drm=$(grep -acF renderD128 $OUT/$1.err 2>/dev/null) $(grep -a tok_s= $OUT/$1.err 2>/dev/null | tail -1) at=$(date +%H:%M:%S)"
    grep -a "requires more than" $OUT/$1.err 2>/dev/null | head -1 | cut -c1-140
}

# 三档 CPU 金标（同题：npred=32 + 默认 prompt，ngl=0）+ 一档 p1 尺子（npred=64）
run_eye b2gold_r1 32 0 ""
run_eye b2gold_r2 32 0 ""
run_eye b2gold_r3 32 0 ""
run_eye b2gold_r4 64 0 "$P1P"
echo "#### B2G_DONE $(date +%H:%M:%S)"
