#!/system/bin/sh
# [gemm_plan G2 ledger-222 重写] prefill 四臂 @ 3K-token agent prompt(830, vendor 路)。
# 判决题(ledger-220 拍2):"app 线 ubatch=512 真走大 N 时 mul_mv GEMV 慢"候测是否过时
#   —— 军械普查见 GEMM 派发段无 adreno 守卫(ADRENO=ON 件), 本腿用数判之。
# 四臂(同一 ling_e2e 件, EXPECT_LIB 红卡):
#   A_islands  env 全 0                岛现状(=税基线)
#   B_r3gemv   MESA_LARGE_N_GEMV=1     vendor 路上应 no-op(Mesa 系 env), 留臂作 no-op 铁证
#   C_q5xgemm  Q5X_GEMM=1              P1 准入 → l4_lm GEMM
#   D_gold     ngl=0                   CPU 金标(只出 logits, 不出性能结论)
# 指标: leg=prefill(pf_ms/prefill_tok_s) + leg=decode(tok_s); 正确性=C vs D prefill
#   logits NMSE + greedy top-1×3(合同第11条修订版; tokmd5 仅线索)。
# 纪律: E2E_NB 撞 "requires more than N unique experts" → 减半重试并记 NB_CAP
#   (=split-MoE clamp 现场实证, 归配置债); 绝不为跑通改 runtime 源码。
G=/data/local/tmp/gemm
EYE=$G/ling_e2e
DTAG=${DTAG:-830}
LING=${LING:-/data/local/tmp/vkl/Ling-3.0-tiny-Q4_0.gguf}
OUT=$G/out
EXPECT_LIB=${EXPECT_LIB:?必填}
TEMP_MAX=${TEMP_MAX:-440}
NB=${NB:-512}
NPRED=${NPRED:-32}
NCTX=${NCTX:-4096}
SHOTS=${SHOTS:-3}
[ -d $OUT ] || mkdir -p $OUT

T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### G2_THERMAL_ABORT batt=$T"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
[ "$SO" = 0 ] || { svc power stayon false >/dev/null 2>&1; echo "#### G2_STAYON $SO ⇒ 归零即退"; exit 17; }
LM=$(md5sum $G/libggml-opencl.so.0.27.0 2>/dev/null | cut -c1-8)
[ "${LM:-none}" = "$EXPECT_LIB" ] || { echo "#### G2_LIB_MD5_ABORT got=${LM:-missing}"; exit 5; }
[ -x $EYE ] && [ -f $LING ] || { echo "#### G2_ABORT eye_or_model"; exit 3; }
PROMPT=$(cat $G/p3k.txt); [ -n "$PROMPT" ] || { echo "#### G2_ABORT no_p3k"; exit 6; }
NB_USED=$NB
run_arm() { # $1=arm $2=env串 $3=ngl $4=shot
    STAMP=$1; ENVS="$2"; NGLV=$3; S=$4
    cd $G
    eval "env $ENVS LD_LIBRARY_PATH=$G E2E_NB=$NB_USED E2E_LOGITDUMP=$OUT/g2_${STAMP}_s$S.lg \
        $EYE $LING $NPRED $NGLV 42 \"\$PROMPT\" $NCTX" \
        >$OUT/g2_${STAMP}_s$S.log 2>$OUT/g2_${STAMP}_s$S.err
    RC=$?
    if grep -q "unique experts" $OUT/g2_${STAMP}_s$S.err 2>/dev/null && [ "$NB_USED" -gt 64 ]; then
        NB_USED=$((NB_USED/2)); echo "#### G2_NB_CAP down to $NB_USED (split-MoE clamp 现场实证)"
        eval "env $ENVS LD_LIBRARY_PATH=$G E2E_NB=$NB_USED E2E_LOGITDUMP=$OUT/g2_${STAMP}_s$S.lg \
            $EYE $LING $NPRED $NGLV 42 \"\$PROMPT\" $NCTX" \
            >$OUT/g2_${STAMP}_s$S.log 2>$OUT/g2_${STAMP}_s$S.err
        RC=$?
    fi
    PF=$(grep "leg=prefill" $OUT/g2_${STAMP}_s$S.err | tail -1)
    DK=$(grep "leg=decode" $OUT/g2_${STAMP}_s$S.err | tail -1)
    echo "#### G2_METRIC device=$DTAG arm=$STAMP shot=$S nb=$NB_USED ngl=$NGLV rc=$RC lib=$LM"
    echo "#### G2_$STAMP.$S $PF"
    echo "#### G2_$STAMP.$S $DK"
}

for S in 1 2 3; do
    run_arm A_islands "GGML_OPENCL_Q5X_GEMM=0" 99 $S
    run_arm B_r3gemv  "GGML_OPENCL_Q5X_GEMM=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1" 99 $S
    run_arm C_q5xgemm "GGML_OPENCL_Q5X_GEMM=1" 99 $S
done
run_arm D_gold "GGML_OPENCL_Q5X_GEMM=0" 0 1
# host 侧比对(python 另册): C vs D 首行 logits NMSE + greedy top-1 ×3;
#   C≈D 且 B≈D ⇒ 差异若存在归 A(A 含岛); C≠D ⇒ P1 新核引入 → 立案回退。
#   头牌指标 = A vs C prefill_tok_s 差 = CPU 岛税定量。
echo "#### G2_DONE out=$OUT (回 host 拉 g2_*.err + g2_*.lg)"
