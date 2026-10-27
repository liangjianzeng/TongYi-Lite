#!/bin/bash
# R-090 制度化：>1GB 设备搬运一律分块+限速（13.58GB 整拉压垮 adbd 血案后立规）
# 用法: ANDROID_ADB_SERVER_PORT=15037 bash lfm_pull_chunked_740.sh [dev=100.109.138.2:5555]
set -u
DEV=${1:-100.109.138.2:5555}
SRC=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
DST=/home/jianzengliang/MyWork/TongYi-Lite/.modelxfer
SP=/data/local/tmp/lfmsplit
A(){ timeout 600 adb -s "$DEV" shell "$1"; }
[ -e "$DST/lfm2.5-24b-a2b-q4_0.gguf.ok" ] && { echo "#### ALREADY_OK"; exit 0; }

echo "#### STEP1_split $(date +%H:%M:%S)"
A "mkdir -p $SP; rm -f $SP/p_*; split -b 1073741824 $SRC $SP/p_ && ls $SP | wc -l"
N=$(A "ls $SP | grep -c '^p_'"); N=$(echo "$N" | tr -dc '0-9')
[ "${N:-0}" -ge 12 ] || { echo "#### SPLIT_FAIL n=$N"; exit 1; }

echo "#### STEP2_devhash $(date +%H:%M:%S)"
A "md5sum $SRC" | tr -dc '0-9a-f\n'

echo "#### STEP3_chunkpull_serial $(date +%H:%M:%S)"
mkdir -p "$DST/parts"
for i in $(seq 1 "$N"); do
  C=$(A "ls $SP | grep '^p_' | sort | sed -n ${i}p" | tr -dc 'a-zA-Z0-9_')
  [ -n "$C" ] || { echo "#### NO_CHUNK_$i"; exit 1; }
  if [ -s "$DST/parts/$C" ]; then echo "skip $C"; continue; fi
  timeout 900 adb -s "$DEV" pull "$SP/$C" "$DST/parts/$C" >/dev/null 2>&1 || { echo "#### PULL_FAIL $C"; exit 1; }
  SZ=$(stat -c %s "$DST/parts/$C" 2>/dev/null || echo 0)
  echo "chunk $C $SZ $(date +%H:%M:%S)"
  sleep 8   # 缓一口气，adbd 血案堵雷
done

echo "#### STEP4_assemble_verify $(date +%H:%M:%S)"
cat $(ls "$DST/parts"/p_* | sort) > "$DST/lfm2.5-24b-a2b-q4_0.gguf"
SZ=$(stat -c %s "$DST/lfm2.5-24b-a2b-q4_0.gguf")
[ "$SZ" = "13578190880" ] || { echo "#### SIZE_BAD $SZ"; exit 1; }
md5sum "$DST/lfm2.5-24b-a2b-q4_0.gguf"
touch "$DST/lfm2.5-24b-a2b-q4_0.gguf.ok"
A "rm -rf $SP"
echo "#### LFM_DONE $(date +%H:%M:%S)"
