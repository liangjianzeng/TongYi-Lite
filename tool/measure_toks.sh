#!/bin/bash
# measure_toks.sh — 740 App decode tok/s 一键测量（Dart VM service 通道，零 UI 盲驱）。
# 前提：app-debug.apk（含 f16 KV）已装；设备解锁空闲；adb -s 98fc9410 在线。
# 可选环境变量：UBATCH=N 同时注入 TONGYI_UBATCH=N（pp 收敛 A/B）。
set -u
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
DEV=98fc9410
DART="/c/dev-tools/flutter/bin/dart.bat"
TOOLDIR="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
PKG=com.dgxspark.tongyilite
MODEL=/data/data/com.dgxspark.tongyilite/app_flutter/models/ling-3.0-tiny-q4_0.gguf

echo "== [1/6] cold start =="
"$ADB" -s $DEV shell am force-stop $PKG
sleep 2
# 可选：TONGYI_UBATCH 注入（pp 63-split 收敛实验）
if [ -n "${UBATCH:-}" ]; then
  printf "GGML_SCHED_DEBUG=2\nGGML_OPENCL_HOST_TIMING=1\nTONGYI_UBATCH=%s\n" "$UBATCH" > /tmp/vk_flags.conf
  MSYS_NO_PATHCONV=1 "$ADB" -s $DEV push "$(cygpath -w /tmp/vk_flags.conf)" /data/local/tmp/vk_flags.conf >/dev/null
  "$ADB" -s $DEV shell run-as $PKG cp /data/local/tmp/vk_flags.conf app_flutter/vk_flags.conf
  echo "vk_flags.conf: SCHED_DEBUG=2 HOST_TIMING=1 TONGYI_UBATCH=$UBATCH"
else
  printf "GGML_SCHED_DEBUG=2\nGGML_OPENCL_HOST_TIMING=1\n" > /tmp/vk_flags.conf
  MSYS_NO_PATHCONV=1 "$ADB" -s $DEV push "$(cygpath -w /tmp/vk_flags.conf)" /data/local/tmp/vk_flags.conf >/dev/null
  "$ADB" -s $DEV shell run-as $PKG cp /data/local/tmp/vk_flags.conf app_flutter/vk_flags.conf
  echo "vk_flags.conf: SCHED_DEBUG=2 HOST_TIMING=1"
fi
"$ADB" -s $DEV logcat -c 2>/dev/null || true
MSYS_NO_PATHCONV=1 "$ADB" -s $DEV shell am start -n $PKG/.MainActivity
sleep 12

echo "== [2/6] locate Dart VM service =="
VMLINE=$("$ADB" -s $DEV logcat -d | grep "Dart VM service is listening" | tail -1)
echo "$VMLINE"
URL_PATH=$(echo "$VMLINE" | grep -oE "http://127\.0\.0\.1:[0-9]+/[^ ]+" | sed 's|http://127.0.0.1||')
PORT=$(echo "$URL_PATH" | grep -oE ":[0-9]+" | tr -d ':')
AUTH=$(echo "$URL_PATH" | grep -oE "/[^/]+/$" | tr -d '/')
MSYS_NO_PATHCONV=1 "$ADB" -s $DEV forward tcp:$PORT tcp:$PORT
WS="ws://127.0.0.1:$PORT/$AUTH/ws"
echo "ws: $WS"

echo "== [3/6] setKvCacheType f16 =="
MSYS_NO_PATHCONV=1 "$DART" "$TOOLDIR/vm_eval.dart" "$WS" "InferenceService().setKvCacheType('f16')"

echo "== [4/6] loadModel (fire) + wait =="
MSYS_NO_PATHCONV=1 "$DART" "$TOOLDIR/vm_eval.dart" "$WS" "InferenceService().loadModel('$MODEL', nCtx: 4096, enableGpu: true, gpuLayers: 100, gpuBackend: 'auto')"
for i in $(seq 1 40); do
  sleep 3
  if "$ADB" -s $DEV logcat -d | grep -q "loadModel result: true"; then echo "LOADED after ~$((i*3))s"; break; fi
done
"$ADB" -s $DEV logcat -d | grep -E "KV cache: type|splits|compute buffer" | head -5

echo "== [5/6] benchmark (warmup32 + 128 tok) =="
MSYS_NO_PATHCONV=1 "$DART" "$TOOLDIR/vm_eval.dart" "$WS" "InferenceService().benchmark(prompt: 'Count slowly from one to thirty.', nRepeats: 1)"
for i in $(seq 1 30); do
  sleep 3
  if "$ADB" -s $DEV logcat -d | grep -q "Benchmark (1 runs)"; then break; fi
done

echo "== [6/6] results =="
"$ADB" -s $DEV logcat -d | grep -E "Benchmark \(|eval time|eval: |prompt=.*tok/s|handleBenchmark.*result|host-timing" | tail -12
MSYS_NO_PATHCONV=1 "$ADB" -s $DEV forward --remove tcp:$PORT 2>/dev/null || true
echo DONE
