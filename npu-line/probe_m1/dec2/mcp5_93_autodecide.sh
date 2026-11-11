#!/bin/bash
# [npu-line] G3: wait for the 740 to return from Doze-adbd-drop (pitfall 32), then run the
# decisive trio automatically. Polls every 2 min up to 90 min; log = rb/probe_decide.log.
RBD=/mnt/e/MyLLM_exp/_repro/rb
ADB=/mnt/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
LOG=$RBD/probe_decide.log
echo "AUTODEcide start $(date +%H:%M:%S)" > $LOG
for i in $(seq 1 45); do
  N=$("$ADB" devices 2>/dev/null | grep -c <redacted-serial>)
  if [ "$N" = "1" ]; then
    echo "DEVICE_BACK $(date +%H:%M:%S) after ${i} polls" >> $LOG
    sleep 5
    break
  fi
  sleep 120
done
N=$("$ADB" devices 2>/dev/null | grep -c <redacted-serial>)
if [ "$N" != "1" ]; then
  echo "DEVICE_NEVER_RETURNED" >> $LOG
  exit 1
fi
bash $RBD/mcp5_93_probe_decide.sh
echo "AUTODECIDEDONE $(date +%H:%M:%S)" >> $LOG
