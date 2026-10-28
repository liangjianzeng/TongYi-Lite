#!/bin/bash
# 醒屏窗口猎人：短促重连→上线即推枪+脱离发射（不点屏！adb shell 腿不需亮屏）。
export ANDROID_ADB_SERVER_PORT=15037
D=100.109.138.2:5555
G=/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/vkh_830/guns
K=/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/vkh_830/lfm_kit2
for i in $(seq 1 90); do
  timeout 20 adb connect $D >/dev/null 2>&1
  st=$(timeout 12 adb devices 2>/dev/null | grep "$D" | awk '{print $2}')
  echo "try$i=$st $(date +%T)"
  if [ "$st" = "device" ]; then
    timeout 60 adb -s $D push $G/lfm_chain.sh /data/local/tmp/lfm_chain.sh 2>&1 | tail -1
    timeout 60 adb -s $D push $K/ling_e2e /data/local/tmp/vkh_lfm2/ling_e2e 2>&1 | tail -1
    timeout 60 adb -s $D shell "chmod 755 /data/local/tmp/vkh_lfm2/ling_e2e /data/local/tmp/lfm_chain.sh; setsid nohup sh /data/local/tmp/lfm_chain.sh >/dev/null 2>&1 & echo CHAIN_FIRED"
    echo FIRED_OK
    exit 0
  fi
  sleep 15
done
echo EXHAUSTED
