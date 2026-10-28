#!/system/bin/sh
# [gemm_plan G2 ledger-220] prefill 四臂 3K-token agent-prompt 腿(830 车道)。
#
# 目的:钉死 L10456"app 线 ubatch=512 真走大 N 时 GEMV 慢"候测 —— 军械普查发现
#   GEMM 派发段入口无 use_adreno_kernels 守卫(:28988 区),R3 准入的 Mesa 512 腿
#   **疑已走 l4_lm GEMM** ⇒ 本腿用数据判"候测是否过时",顺带量 P1 的 prefill 收益。
# 四臂(同 stack 律:全臂同 lib md5,EXPECT_LIB 红卡):
#   A islands = 现状(两 env 全 0)                    —— CPU 岛税基线
#   B r3gemv  = GGML_OPENCL_MESA_LARGE_N_GEMV=1       —— R3 放 GEMV
#   C gemm    = B + GGML_OPENCL_Q5X_GEMM=1            —— l4_lm GEMM 臂(P1)
#   D gold    = --ngl 0(金标尺,不出性能结论只出正文)  —— CPU 金标臂(甄别协议用)
# 指标:prefill tok/s + TTFT(件内计时口径, leg=prefill METRIC 行);
#   正确性闸(合同第11条修订版, tokmd5=假闸已废):greedy top-k 一致率×3(D 臂为尺)。
# ⚠ E2E_NB=512 与 ling 件 bank/k 的物理相容性未证(R-083 nb=16 窗口血案参照)——
#   先 PROBE=1 单臂摸 rc,撞 llama-context.cpp:1944 ASSERT 则本腿改走 app 线(logcat 口径),入账。
# 铁律:不动屏幕;腿前机检 stay_on=0;热闸 440;腿完 15 分钟 GEMV 侧不动表。
R=/data/local/tmp/mesa_clrt_1026
G=/data/local/tmp/gemm
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
LIB=$G/libggml-opencl.so.0.27.0
EYE=$R/bin/ling_e2e_v4ld
LING=${LING:-/data/local/tmp/ling/bailingmoe3-q5_0-ling.gguf}
P3K=$G/p3k.txt
OUT=$G/out
EXPECT_LIB=${EXPECT_LIB:-f0d564da2}
TEMP_MAX=${TEMP_MAX:-440}
PROBE=${PROBE:-0}
NB=${NB:-512}
[ -d $OUT ] || mkdir -p $OUT

T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### G2_THERMAL_ABORT batt=$T"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
[ "$SO" = 0 ] || { svc power stayon false >/dev/null 2>&1; echo "#### G2_STAYON $SO ⇒ 归零即退(铁律)"; exit 17; }
M=$(md5sum $LIB 2>/dev/null | cut -c1-8); [ "${M:-none}" = "$EXPECT_LIB" ] || { echo "#### G2_LIB_MD5_ABORT got=${M:-missing}"; exit 5; }
[ -f $P3K ] || { echo "#### G2_ABORT reason=no_p3k (先跑 G0 落 3K prompt)"; exit 3; }
P3K_BYTES=$(wc -c <$P3K | tr -dc '0-9')
[ "$P3K_BYTES" -ge 6000 ] || { echo "#### G2_P3K_TOO_SHORT bytes=$P3K_BYTES (3K-token agent 形态 ≈ 中文字节×3, 拒射防伪 3K)"; exit 6; }

run_arm() {
    STAMP=$1; ENVS=$2; NGLV=$3
    eval "env $ENVS LD_LIBRARY_PATH=$LP OPENCL_ICD_VENDORS=$ICD \
        $LOADER $EYE --model $LING --ngl $NGLV --seed 42 --eos 151645 --temp 0 \
        --npred 32 --prompt-file $P3K E2E_NB=$NB" \
        >$OUT/g2_${STAMP}.log 2>&1
    RC=$?
    PREFILL=$(grep -oE "prefill[^0-9]*[0-9]+\.[0-9]+ *t/s" $OUT/g2_${STAMP}.log | tail -1)
    TTFT=$(grep -oE "ttft[^0-9]*[0-9]+" $OUT/g2_${STAMP}.log | tail -1)
    TOPK=$(grep "^topk " $OUT/g2_${STAMP}.log | head -32 | md5sum | cut -c1-8)   # 件内 topk dump(件若无此出口, PROBE 阶段确认)
    TOK=$(grep -c "^tok " $OUT/g2_${STAMP}.log 2>/dev/null || echo 0)
    echo "#### G2_METRIC leg=prefill device=830 arm=$STAMP nb=$NB rc=$RC prefill='${PREFILL:-NA}' ttft='${TTFT:-NA}' topk3=$TOPK tok=$TOK lib=$M"
}

if [ "$PROBE" = 1 ]; then run_arm probe "GGML_OPENCL_Q5X_GEMM=0" 99; echo "#### G2_PROBE tail:"; tail -8 $OUT/g2_probe.log; exit 0; fi

run_arm A_islands "GGML_OPENCL_Q5X_GEMM=0" 99
run_arm B_r3gemv  "GGML_OPENCL_Q5X_GEMM=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1" 99
run_arm C_q5xgemm "GGML_OPENCL_Q5X_GEMM=1 GGML_OPENCL_MESA_LARGE_N_GEMV=1" 99
run_arm D_gold    "GGML_OPENCL_Q5X_GEMM=0" 0
# 判定(ledger-220):
#  1) B/C 臂 prefill ≫ A = CPU 岛税定量;"B≈C" ⇒ Mesa 大 N 早已 GEMM,候测结案为过时预言;
#  2) C<A ⇒ l4_lm 在 830 反而慢 ⇒ 立案回退 P1 默认(本来就没翻,维持);
#  3) topk3: C 与 D 不一致 ⇒ 走甄别协议(D=CPU 金标;区分新核引入 vs 与生俱来核级竞态, 后者移交 GEMV 侧独立案, 不并案);
#  4) 全臂 tokmd5 仅作线索不作闸(4B 假闸定案 #219)。
echo "#### G2_DONE out=$OUT"
