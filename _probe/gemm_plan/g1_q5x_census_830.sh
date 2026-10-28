#!/system/bin/sh
# [gemm_plan G1 ledger-222 重写] q5_0/q5_1 白名单岛 census 腿(830, vendor /vendor/lib64 路 = app 线形态)。
#
# 现场定案(17:1x 实探):ling 真主=/data/local/tmp/vkl/Ling-3.0-tiny-Q4_0.gguf(bailingmoe3 24L
#   128e×k8 混量, q5_0 共享专家=岛受害者);EYE=_probe/moe_probe/ling_e2e(NDK 静态系, 姿势=
#   `ling_e2e <model> <npred> <ngl> <seed> <prompt> <nctx>`;ling830_162410.log 同族姿势)。
# 双臂:A=env OFF(零扰动铁证:岛数须=基线) B=env ON(岛 36/37→个位 + tok 非空)。
# 同 stack 律:两臂同一 ling_e2e 件(EXPECT_LIB 红卡=该件 libggml-opencl md5);与 sibling
#   lingfix 栈(d1582af7)绝对数不可互抄, A/B 内部对比自证。
# 铁律:stay_on 非 0 → 归零 exit 17;热闸 440;腿完 15 分钟 GEMV 侧不动表。
G=/data/local/tmp/gemm
EYE=$G/ling_e2e
DTAG=${DTAG:-830}
LING=${LING:-/data/local/tmp/vkl/Ling-3.0-tiny-Q4_0.gguf}
OUT=$G/out
EXPECT_LIB=${EXPECT_LIB:?必填=ling_e2e 栈 libggml-opencl md5 前8位}
TEMP_MAX=${TEMP_MAX:-440}
PROBE=${PROBE:-0}
NB=${NB:-512}
NPRED=${NPRED:-32}
NCTX=${NCTX:-4096}
[ -d $OUT ] || mkdir -p $OUT

T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### G1_THERMAL_ABORT batt=$T max=$TEMP_MAX"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
[ "$SO" = 0 ] || { svc power stayon false >/dev/null 2>&1; echo "#### G1_STAYON $SO ⇒ 已归零即退(绝对铁律, 追登记者)"; exit 17; }
LM=$(md5sum $G/libggml-opencl.so.0.27.0 2>/dev/null | cut -c1-8)
[ "${LM:-none}" = "$EXPECT_LIB" ] || { echo "#### G1_LIB_MD5_ABORT got=${LM:-missing} expect=$EXPECT_LIB"; exit 5; }
[ -x $EYE ] && [ -f $LING ] || { echo "#### G1_ABORT reason=eye_or_model eye=$EYE ling=$LING"; exit 3; }
PROMPT=$(cat $G/p3k.txt)
[ -n "$PROMPT" ] || { echo "#### G1_ABORT reason=no_p3k"; exit 6; }

run_arm() { # $1=arm $2=env串 [$3=ngl]
    STAMP=$1; ENVS="$2"; NGLV=${3:-99}
    cd $G
    eval "env $ENVS LD_LIBRARY_PATH=$G GGML_SCHED_DEBUG=2 E2E_NB=$NB \
        $EYE $LING $NPRED $NGLV 42 \"\$PROMPT\" $NCTX" \
        >$OUT/g1_${STAMP}.log 2>&1
    RC=$?
    LOADCPU=$(grep -c "offloaded to CPU" $OUT/g1_${STAMP}.log 2>/dev/null; true)
    SCHEDCPU=$(grep "MUL_MAT" $OUT/g1_${STAMP}.log 2>/dev/null | grep -c "CPU"; true)
    PF=$(grep "leg=prefill" $OUT/g1_${STAMP}.log | tail -1)
    DK=$(grep "leg=decode" $OUT/g1_${STAMP}.log | tail -1)
    TOKB=$(wc -c <$OUT/g1_${STAMP}.log.stdout 2>/dev/null; true)
    echo "#### G1_METRIC device=$DTAG arm=$STAMP nb=$NB rc=$RC loadcpu=$LOADCPU schedmulmat_cpu=$SCHEDCPU lib=$LM"
    echo "#### G1_$STAMP $PF"
    echo "#### G1_$STAMP $DK"
}

# stdout(tok)与 stderr(日志)分家: run_arm 里 eval 一起重定向了, tok 走 stdout 文件
# (简化: 上面 2>&1 合流,tok 混在日志里 → census 不看 tokmd5, 只看岛; tok 判定在 G2)
if [ "$PROBE" = 1 ]; then
    run_arm probe "GGML_OPENCL_Q5X_GEMM=0" 99
    echo "#### G1_PROBE tail:"; tail -6 $OUT/g1_probe.log
    exit 0
fi

run_arm off "GGML_OPENCL_Q5X_GEMM=0" 99
run_arm on  "GGML_OPENCL_Q5X_GEMM=1" 99
# 验收闸(ledger-222): off.schedmulmat_cpu==基线(R-115=37, 以本次 off 实测为准并回写 ledger);
# on.schedmulmat_cpu ≤ 5 且 decode tok_s>0。不符=立案:on 臂仍岛 → 查 supports_op 门机检路径。
echo "#### G1_DONE out=$OUT"
