#!/bin/bash
# [C33] Resilient chunk push (Git Bash edition: Windows adb + E:/ host paths + device-path guard).
# Usage: push_resilient_gb.sh <serial> <host_E_path> <dev_path>   (chunks pre-split in E:/MyLLM_exp/_chunk)
export MSYS_NO_PATHCONV=1
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
S=$1; HOST=$2; DEV=$3
CH_WIN="E:/MyLLM_exp/_chunk"; CH_UNIX="E:/MyLLM_exp/_chunk"
shopt -s nullglob
parts=($CH_UNIX/part_*)
TOTAL=${#parts[@]}
i=0
for f in "${parts[@]}"; do
  i=$((i+1))
  base=$(basename "$f")
  want=$(md5sum "$f" | awk '{print $1}')
  ok=0
  for try in 1 2 3 4 5 6; do
    have=$("$ADB" -s "$S" shell "md5sum ${DEV}.${base} 2>/dev/null" | tr -d '\r' | awk '{print $1}')
    if [ "$have" == "$want" ]; then ok=1; break; fi
    "$ADB" disconnect "$S" >/dev/null 2>&1
    sleep 1
    "$ADB" connect "$S" >/dev/null 2>&1
    sleep 1
    "$ADB" -s "$S" push "$CH_WIN/$base" "${DEV}.${base}" >/dev/null 2>&1
    sleep 1
  done
  if [ $ok -ne 1 ]; then echo "CHUNK_FAIL $base after 6 tries"; exit 1; fi
  echo "[$i/$TOTAL] $base ok"
done
"$ADB" -s "$S" shell "rm -f $DEV; touch $DEV; for f in ${DEV}.part_*; do cat \$f >> $DEV; rm \$f; done" 2>&1 | tr -d '\r'
WANT=$(md5sum "$HOST" | awk '{print $1}')
GOT=$("$ADB" -s "$S" shell "md5sum $DEV" | tr -d '\r' | awk '{print $1}')
echo "HOST_MD5=$WANT DEV_MD5=$GOT"
if [ "$GOT" == "$WANT" ]; then echo "PUSH_VERIFY_OK"; exit 0; fi
echo "PUSH_VERIFY_MISMATCH"; exit 1
