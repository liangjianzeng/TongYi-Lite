#!/usr/bin/env bash
# [gemm_plan G0 ledger-220] host 侧编件+影子双名 push+3K prompt 落盘(合同第7条:自建 build dir,
# 不碰 build-x4/vkh_batched/glibc-build2;合同第4条:影区 /data/local/tmp/gemm,vkh_batched 不碰)。
# 用法(host, DGX Spark): bash _probe/gemm_plan/g0_build_push_830.sh [--no-push]
set -u
DEV=${DEV:-100.75.247.55:5555}          # 830=本会话车道;740=GEMV SERIAL 车道勿指
PORT=${PORT:-15037}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
BD=$REPO/_probe/moe_probe/build-gemm    # GEMM 侧专属 cmake dir(首次 configure,后续增量)
G=/data/local/tmp/gemm
ADB="adb -P $PORT -s $DEV"

if [ ! -f "$BD/build.ninja" ]; then
    # 配置方子 = 逐字抄 build-x4/CMakeCache(仓内 OpenCL stub + EMBED_KERNELS + ADRENO=ON)
    cmake -S "$REPO/third_party/llama.cpp" -B "$BD" -G Ninja \
        -DGGML_OPENCL=ON -DGGML_OPENCL_EMBED_KERNELS=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=ON \
        -DGGML_OPENCL_TARGET_VERSION=300 -DGGML_OPENCL_PROFILING=OFF \
        -DOpenCL_INCLUDE_DIR="$REPO/third_party/OpenCL-Headers" \
        -DOpenCL_LIBRARY="$REPO/_probe/oclstub_build/opencl-stub/libopencl_stub.so" \
        -DGGML_CCACHE=OFF -DCMAKE_BUILD_TYPE=Release || { echo "#### G0_CONFIGURE_FAIL"; exit 2; }
fi
ninja -C "$BD" ggml-opencl || { echo "#### G0_BUILD_FAIL"; exit 2; }
SO=$BD/ggml/src/ggml-opencl/libggml-opencl.so.0.27.0
MD5=$(md5sum "$SO" | cut -c1-8)
echo "#### G0_BUILT md5=$MD5 size=$(stat -c%s "$SO")"

# 影子双名律(#23 入律):设备上真件 + 同名副本,proof-of-load 靠 logcat dlopen 路径指认
if [ "${1:-}" != "--no-push" ]; then
    $ADB shell mkdir -p $G
    $ADB push "$SO" $G/libggml-opencl.so.0.27.0 || { echo "#### G0_PUSH_FAIL(dev 掉线?息屏=正常,等用户勿点屏)"; exit 3; }
    $ADB push "$SO" $G/.libggml-opencl.so.0.27.0.shadow
    DEVMD5=$($ADB shell "md5sum $G/libggml-opencl.so.0.27.0" | cut -c1-8)
    [ "$DEVMD5" = "$MD5" ] || { echo "#### G0_MD5_MISMATCH host=$MD5 dev=$DEVMD5"; exit 4; }
    echo "#### G0_PUSHED md5=$MD5 (G1/G2 的 EXPECT_LIB 填此前缀)"
fi

# 3K-token agent 形态 prompt(中文≈字节/3 ⇒ ≥9KB):真实 agent 首回合形态 =
# 系统提示词 + 工具定义 JSON + 若干历史轮,而非散文。
$ADB shell mkdir -p $G 2>/dev/null
{
  echo "你是TongYi-Lite智能体。工具调用规则:严格输出JSON对象,含name与arguments两个键;name必须来自注册表;不确定时先read_file再决策;失败重试至多一次。"
  for t in read_file write_file list_dir web_search python_exec export_file load_skill todo_write; do
    echo "{\"name\":\"$t\",\"description\":\"${t}工具:供智能体在任务执行中调用\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"}},\"required\":[]},\"max_uses\":5}"
  done
  for i in $(seq 1 40); do
    echo "用户第${i}轮: 帮我核对第${i}章的数据表并把异常项标注出来,注意预算表与出货表口径要一致,引用的数字保留两位小数。"
    echo "助手第${i}轮: 已完成第${i}章核对: 共检查128行,发现3处口径不一致(第7/42/96行),已按预算表口径统一标注,两位小数对齐,汇总差异合计1,283.45万元,详见标注版表格。"
  done
  echo "请把以上所有轮次里出现过的异常项做一次总复盘,按章分组列出,并给出下一轮修复优先级建议。"
} > /tmp/p3k.txt
BYTES=$(wc -c </tmp/p3k.txt | tr -dc '0-9')
if [ "${1:-}" != "--no-push" ]; then
    $ADB push /tmp/p3k.txt $G/p3k.txt >/dev/null 2>&1
    echo "#### G0_P3K bytes=$BYTES pushed (G2 红卡线 ≥6000)"
else
    echo "#### G0_P3K bytes=$BYTES local-only (/tmp/p3k.txt)"
fi
echo "#### G0_DONE"
