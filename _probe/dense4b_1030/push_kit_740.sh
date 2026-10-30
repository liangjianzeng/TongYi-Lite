#!/usr/bin/env bash
# [dense4b_1030] host 侧：把 bench 套件 + 4B 模型推到指定设备影子目录并 md5 机检。
# 用法: bash push_kit_740.sh <port> <serial> [model_path]
#   port/serial 例：5037 98fc9410  (740)   |   15037 8b1e8747  (K40)
set -u
PORT=${1:?port}; DEV=${2:?serial}; MODEL=${3:-/home/jianzengliang/MyWork/TongYi-Lite/models-4b/Qwen3.5-4B-Q4_K_M.gguf}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
BD=$REPO/_probe/dense4b_1030/build/bin
G=/data/local/tmp/dense4b_1030
ADB="adb -P $PORT -s $DEV"
[ -d "$BD" ] || { echo "#### NO_BUILDDIR $BD"; exit 2; }
[ -f "$MODEL" ] || { echo "#### NO_MODEL $MODEL"; exit 2; }

$ADB shell "mkdir -p $G" || { echo "#### DEV_GONE"; exit 3; }
for f in llama-cli llama-bench libggml.so libggml-base.so libggml-cpu.so libggml-opencl.so \
         libllama.so libllama-common.so libllama-cli-impl.so libllama-bench-impl.so libc++_shared.so; do
    [ -f "$BD/$f" ] || { echo "#### MISSING $f"; exit 4; }
    $ADB push "$BD/$f" $G/$f >/dev/null || { echo "#### PUSH_FAIL $f"; exit 5; }
    H=$(md5sum "$BD/$f" | cut -c1-8); D=$($ADB shell "md5sum $G/$f" | tr -d '\r' | cut -c1-8)
    [ "$H" = "$D" ] || { echo "#### MD5_MISMATCH $f host=$H dev=$D"; exit 6; }
    echo "#### OK $f $H"
done
$ADB push "$REPO/_probe/dense4b_1030/ab_drain_740.sh" $G/ab_drain.sh >/dev/null || { echo "#### PUSH_FAIL script"; exit 7; }
if ! $ADB shell "[ -f $G/$(basename "$MODEL") ]" 2>/dev/null | grep -q .; then :; fi
DEVMD5=$($ADB shell "md5sum $G/$(basename "$MODEL") 2>/dev/null" | tr -d '\r' | cut -c1-8)
HOSTMD5=$(md5sum "$MODEL" | cut -c1-8)
if [ "$DEVMD5" != "$HOSTMD5" ]; then
    echo "#### MODEL_PUSH ($HOSTMD5) …"
    $ADB push "$MODEL" $G/ >/dev/null || { echo "#### PUSH_FAIL model"; exit 8; }
    DEVMD5=$($ADB shell "md5sum $G/$(basename "$MODEL")" | tr -d '\r' | cut -c1-8)
fi
[ "$DEVMD5" = "$HOSTMD5" ] || { echo "#### MODEL_MD5_MISMATCH host=$HOSTMD5 dev=$DEVMD5"; exit 9; }
echo "#### MODEL_OK $(basename "$MODEL") $HOSTMD5"
$ADB shell "chmod 755 $G/llama-cli $G/llama-bench $G/ab_drain.sh; ls -la $G" | tail -20
echo "#### PUSH_DONE dev=$DEV dir=$G"
