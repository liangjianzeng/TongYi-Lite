#!/system/bin/sh
# [dense4b_1030] 4B 稠密 OpenCL 正确性腿：排空档 A/B 的数值闸。
# 用法（设备侧）: sh corr_4b.sh <dir> <tag> [arms]   arms 默认 IDLE0,IDLE2,CPU
# 判据（4B 与生俱来非确定性 ⇒ tokmd5 是假闸，见执行记录 R-? 队列4 判词修正）：
#   1) 退化检测：输出非空、无单字符刷屏（同一字符占比 >0.6 判 DEGENERATE）、无 32×'!' 形；
#   2) 算力小案：17*23 必须出现 391；fib 案必须出现 "def fib"；
#   3) CPU 金标存在性：CPU 臂作可读性金标准；GPU 两臂与 CPU 金标的"同案通过率"必须一致。
D=$1; TAG=$2; ARMS=${3:-IDLE0,IDLE2,CPU}
M=${MODEL:-$D/Qwen3.5-4B-Q4_K_M.gguf}
cd "$D" || exit 1
mkdir -p out
export LD_LIBRARY_PATH=$D GGML_DISABLE_VULKAN=1
LIB=$(md5sum ./libggml-opencl.so | cut -c1-8)
echo "=== corr tag=$TAG lib=$LIB model=$M arms=$ARMS ==="
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
        env $K timeout 900 ./llama-cli -m "$M" -p "$PR" -n 64 --temp 0 -ngl $NGL \
            --no-display-prompt -c 2048 -s 42 > out/${TAG}_${A}_p$P.raw 2> out/${TAG}_${A}_p$P.err
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
