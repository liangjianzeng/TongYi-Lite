#!/system/bin/sh
# [dense4b_1030] 4B 稠密 OpenCL prefill/decode 排空税 A/B。
# 用法（设备侧）: sh ab_drain_740.sh <dir> <tag> <rounds> [arms...]
#   dir   = bench 套件目录（含 llama-bench / lib*.so / 模型）
#   arms  = 逗号分隔的臂名，默认 DEF,IDLE0,SMART
# 口径：同 llama-bench -ngl 99 -fa 0 -p 512 -n 128 -r 1，逐臂交替（同轮 A/B），
#       每臂前后打热闸 + OpenCL 驱动串（ICD 误标案铁律）。
D=$1; TAG=$2; R=${3:-2}; ARMS=${4:-DEF,IDLE0,SMART}
M=${MODEL:-$D/Qwen3.5-4B-Q4_K_M.gguf}
cd "$D" || exit 1
mkdir -p out
export LD_LIBRARY_PATH=$D
export GGML_DISABLE_VULKAN=1
LIB=$(md5sum ./libggml-opencl.so | cut -c1-8)
echo "=== ab tag=$TAG dir=$D lib=$LIB model=$M rounds=$R arms=$ARMS ==="
i=1
while [ $i -le $R ]; do
    for A in $(echo $ARMS | tr ',' ' '); do
        case $A in
            DEF)   K="" ;;
            IDLE0) K="GGML_OPENCL_NDRANGE_IDLE=0" ;;
            IDLE2) K="GGML_OPENCL_NDRANGE_IDLE=2" ;;
            SMART) K="GGML_OPENCL_SMART_DRAIN=1" ;;
            NOSMART) K="GGML_OPENCL_SMART_DRAIN=0" ;;
            KS0)   K="GGML_OPENCL_NDRANGE_IDLE=0 GGML_OPENCL_KERNEL_SYNC=0" ;;
            *) case $A in *=*) K="$A" ;; *) echo "#### BAD_ARM $A"; exit 4 ;; esac ;;
        esac
        T0=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
        env $K timeout 600 ./llama-bench -m "$M" -ngl 99 -fa 0 -p ${PP:-512} -n ${TG:-128} -r 1 -t 8 \
            > out/${TAG}_${A}_r$i.txt 2> out/${TAG}_${A}_r$i.err
        RC=$?
        T1=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
        DRV=$(grep -m1 -E "default device:|selected platform:" out/${TAG}_${A}_r$i.err | tr -d '\r')
        POL=$(grep -m1 "drain policy" out/${TAG}_${A}_r$i.err | tr -d '\r')
        echo "-- arm=$A round=$i rc=$RC temp=$T0->$T1 env=[$K]"
        grep -iE "^\| *qwen" out/${TAG}_${A}_r$i.txt | head -4
        echo "   drv: $DRV"
        echo "   pol: ${POL:-<none:旧 lib>}"
        grep -c "" out/${TAG}_${A}_r$i.err | sed 's/^/   errlines=/'
        sleep 45
    done
    i=$((i+1))
done
echo "=== ab done tag=$TAG ==="
