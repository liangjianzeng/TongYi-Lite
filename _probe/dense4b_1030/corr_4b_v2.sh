#!/system/bin/sh
# [dense4b_1030] v2 数值闸：修正 v1 的判据失效问题。
# v1 实测（c740a, 2026-10-31）：18/18 三臂全无退化，但 p3(391)/p4(def fib) 连 CPU 金标臂都不过——
#   原因 = Qwen3.5-4B 是 thinking 模型，-n 64 全被思考过程吃掉，最终答案轮不到出现。
# v2 改动（仅两处）：① 各 prompt 追加 "" 软开关；② -n 64 → 128 给答案留余量。
# 其余（arms/seed/temp/ctx/冷却）与 v1 逐字一致。
# 用法（设备侧）: sh corr_4b_v2.sh <dir> <tag> [arms]   arms 默认 IDLE0,IDLE2,CPU
D=$1; TAG=$2; ARMS=${3:-IDLE0,IDLE2,CPU}
M=${MODEL:-$D/Qwen3.5-4B-Q4_K_M.gguf}
cd "$D" || exit 1
mkdir -p out
export LD_LIBRARY_PATH=$D GGML_DISABLE_VULKAN=1
LIB=$(md5sum ./libggml-opencl.so | cut -c1-8)
echo "=== corr tag=$TAG lib=$LIB model=$M arms=$ARMS v2=reasonoff,n448 ==="
P1="请详细介绍一下中国的四大发明，分别说明历史背景与技术要点，分四段展开。"
P2="Explain in detail why the sky is blue, in three short paragraphs."
P3="计算 17 乘以 23 等于多少？请给出推理过程。"
P4="写一个 Python 函数 fib(n)，返回第 n 个斐波那契数，并给出示例调用。"
P5="用「春天」「火车」「信」三个词写一首四行诗。"
P6="介绍一下长城的历史和建筑特点，分三段。"
i=1
for A in $(echo $ARMS | tr ',' ' '); do
    case $A in
        IDLE0) K="GGML_OPENCL_NDRANGE_IDLE=0" ;;
        IDLE2) K="GGML_OPENCL_NDRANGE_IDLE=2" ;;
        CPU)   K="";                  NGL=0 ;;
        *)     K="$A";                NGL=99 ;;
    esac
    [ "$A" = "CPU" ] || NGL=99
    for P in 1 2 3 4 5 6; do
        eval PR=\$P$P
        env $K timeout 900 ./llama-cli -m "$M" -p "$PR" -n 448 --temp 0 -ngl $NGL \
            --no-display-prompt -c 2048 --reasoning off -s 42 > out/${TAG}_${A}_p$P.raw 2> out/${TAG}_${A}_p$P.err
        RC=$?
        sed -e '/\[ Prompt:/d' -e '/^>/d' -e '/^Exiting/d' -e '/^$/d' out/${TAG}_${A}_p$P.raw > out/${TAG}_${A}_p$P.txt
        BY=$(wc -c < out/${TAG}_${A}_p$P.txt | tr -dc '0-9')
        MD=$(md5sum out/${TAG}_${A}_p$P.txt | cut -c1-8)
        TOKS=$(grep -E "Prompt:|Evaluation:" out/${TAG}_${A}_p$P.raw | tail -1 | tr -d '\n' | tr -s ' ')
        echo "#### CORRRESULT arm=$A case=p$P round=$i rc=$RC bytes=$BY md5=$MD $TOKS"
        i=$((i+1))
    done
    sleep 40
done
echo "### CORR_DONE tag=$TAG"
