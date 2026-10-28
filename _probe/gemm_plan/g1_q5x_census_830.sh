#!/system/bin/sh
# [gemm_plan G1 ledger-220] q5_0/q5_1 白名单岛 census 腿(830 车道;GEMV 侧 740 SERIAL 律,本会话不占)。
#
# 目的:验 P1 diff(env GGML_OPENCL_Q5X_GEMM=1)把 ling(bailingmoe3)装载期被"假想 m=512"
#   流放的 **36 枚 q5_0 共享专家 MUL_MAT CPU 岛**打到个位(R-115 d2 普查基线=37 岛)。
# 双臂:A=env OFF(基线,须逐字节=旧行为, 零扰动铁证);B=env ON(岛数 36→个位 + greedy tok 非空)。
# 口径:ling_e2e @ E2E_NB=512(装载期判决臂;运行期真 512 prefill 见 G2 腿);
#   GGML_SCHED_DEBUG=2 数岛;greedy seed 固定;同 stack 律 = 只认 EXPECT_LIB md5(升件重拍,
#   现网 f0d564da2;A路 6827dbc16c 过 LFM 真验后可换, 换须两臂全重跑)。
# 件纪律:LP 含 P1 diff(commit 6a0992ae)。md5 红卡;金库件一字不许动。
# 铁律:绝不动屏幕(无 svc power stayon true / 无 KEYCODE_*);腿前机检 stay_on 必 0,非 0 归零即 abort。
# 热闸:>TEMP_MAX(默认440, 与 GEMV 侧同闸) ABORT;本腿完 15 分钟内 GEMV 侧不动表(合同第5条)。
# 用法(host):adb -P 15037 -s 100.75.247.55:5555 push 本文件 /data/local/tmp/gemm/
#            adb ... shell setsid nohup sh /data/local/tmp/gemm/g1_q5x_census_830.sh </dev/null >out 2>&1 &
# 首次落地先 PROBE=1 探路(bin/model 存在性 + rc), 定案再跑正式双臂。
R=/data/local/tmp/mesa_clrt_1026          # 金库栈根(与 b 线共用, 只读)
G=/data/local/tmp/gemm                     # GEMM 侧影区(合同第4条: vkh_batched 不碰)
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
LIB=$G/libggml-opencl.so.0.27.0            # 影子件(P1 编成后 push 到此, 双名律见 G0)
EYE=$R/bin/ling_e2e_v4ld                   # 装载/判决探针用 ling 件
LING=${LING:-/data/local/tmp/ling/bailingmoe3-q5_0-ling.gguf}   # 正主路径 PROBE 腿确认后钉死
OUT=$G/out
EXPECT_LIB=${EXPECT_LIB:-f0d564da2}        # 同 stack 律红卡前缀
TEMP_MAX=${TEMP_MAX:-440}
PROBE=${PROBE:-0}
[ -d $OUT ] || mkdir -p $OUT

# --- 四闸(模板=vkh R-108) -----------------------------------------------------
T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9'); [ -n "${T:-}" ] || T=0
[ "$T" -gt "$TEMP_MAX" ] && { echo "#### G1_THERMAL_ABORT batt=$T max=$TEMP_MAX"; exit 4; }
SO=$(settings get global stay_on_while_plugged_in 2>/dev/null | tr -dc '0-9'); [ -n "${SO:-}" ] || SO=0
if [ "$SO" != 0 ]; then
    echo "#### G1_STAYON $SO ⇒ 归零(绝对铁律)"
    svc power stayon false >/dev/null 2>&1
    echo "#### G1_STAYON_AFTER $(settings get global stay_on_while_plugged_in 2>/dev/null)"
    exit 17
fi
M=$(md5sum $LIB 2>/dev/null | cut -c1-8); [ "${M:-none}" = "$EXPECT_LIB" ] || { echo "#### G1_LIB_MD5_ABORT got=${M:-missing} expect=$EXPECT_LIB (同stack律; 升件先重拍对拍再改EXPECT)"; exit 5; }
[ -x $EYE ] && [ -f $LING ] || { echo "#### G1_ABORT reason=no_bin_or_model (先跑 PROBE=1)"; exit 3; }

run_arm() { # $1=arm名 $2=env串
    STAMP=$1; shift; ENVS="$1"
    # 注意: env 串里不含单引号
    eval "env $ENVS LD_LIBRARY_PATH=$LP OPENCL_ICD_VENDORS=$ICD \
        GGML_SCHED_DEBUG=2 \
        $LOADER $EYE --model $LING --ngl 99 --seed 42 --eos 151645 --temp 0 --npred 32" \
        >$OUT/g1_${STAMP}.log 2>&1
    RC=$?
    ISLANDS=$(grep -c "offloaded to CPU" $OUT/g1_${STAMP}.log 2>/dev/null || echo NA)
    MULMAT_CPU=$(grep "MUL_MAT" $OUT/g1_${STAMP}.log 2>/dev/null | grep -c "CPU" || echo NA)
    TOKBYTES=$(grep -c "^tok " $OUT/g1_${STAMP}.log 2>/dev/null || echo 0)
    TOKMD5=$(grep "^tok " $OUT/g1_${STAMP}.log 2>/dev/null | md5sum | cut -c1-8)
    echo "#### G1_METRIC leg=prefill device=830 arm=$STAMP rc=$RC islands=$ISLANDS mulmat_cpu=$MULMAT_CPU tokbytes=$TOKBYTES tokmd5=$TOKMD5 lib=$M"
}

if [ "$PROBE" = 1 ]; then
    run_arm probe "GGML_OPENCL_Q5X_GEMM=0 E2E_NB=512"
    echo "#### G1_PROBE_DONE tail:"; tail -5 $OUT/g1_probe.log
    exit 0
fi

run_arm off "GGML_OPENCL_Q5X_GEMM=0 E2E_NB=512"
run_arm on  "GGML_OPENCL_Q5X_GEMM=1 E2E_NB=512"
# 验收闸(ledger-220): arm_off.mulmat_cpu == 基线37±0(零扰动);arm_on.mulmat_cpu ≤ 5 且 tokbytes>0。
# tokmd5 两臂不同 ≠ 过/不过 —— 只作线索;数值判定走 G3(logits-diff+top-k×3, 合同第11条修订版)。
echo "#### G1_DONE out=$OUT"
