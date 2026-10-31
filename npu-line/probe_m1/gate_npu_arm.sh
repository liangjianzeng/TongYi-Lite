#!/system/bin/sh
# NPU 臂正式闸门测量（M1 go/no-go 用）——ctx 就位后执行
# 用法: sh gate_npu_arm.sh <ctx文件名> <tag>   （在 /data/local/tmp/npu_m1 下）
# 协议: 3 轮 × 90s 冷却；每轮 net-run 全量时间戳入档；t/s = 512 / graph_execute 秒
# 功耗: 宿主机侧并行跑 pwr_sample.py（电池模式！拔线），两边时间戳对齐后算 watts/token
D=/data/local/tmp/npu_m1
CTX=$1
TAG=$2
[ -z "$CTX" ] && { echo "usage: sh gate_npu_arm.sh <ctx> <tag>"; exit 1; }
cd $D || exit 1
export LD_LIBRARY_PATH=$D/lib
export ADSP_LIBRARY_PATH="//data/local/tmp/npu_m1/lib;native"
mkdir -p out
LIBMD5=$(md5sum $D/lib/libQnnHtp.so | cut -c1-8)
CTXMD5=$(md5sum $D/$CTX | cut -c1-8)
echo "=== gate_npu tag=$TAG lib=$LIBMD5 ctx=$CTX ctxmd5=$CTXMD5 date=$(date)"
i=1
while [ $i -le 3 ]; do
  echo "--- rep $i start $(date +%T)"
  $D/bin/qnn-net-run --backend $D/lib/libQnnHtp.so \
      --retrieve_context $D/$CTX \
      --input_list $D/input_list.txt \
      --output_dir $D/out/rep$i \
      --profiling_options detailed 2>&1 | tee $D/out/npu_${TAG}_rep$i.log
  echo "--- rep $i end $(date +%T)"
  if [ $i -lt 3 ]; then
    echo "cooldown 90s..."; sleep 90
  fi
  i=$((i+1))
done
echo "=== done; 解析各 rep 日志里的 graph execute 时间戳，t/s = 512/秒；三次中位数入档"
