set -e
ADB="D:/TongYi-Lite/.tmp_platform_tools/platform-tools/adb.exe"
for S in <redacted-serial-740> <redacted-lan>:5555; do
  echo "===== DEVICE $S ====="
  "$ADB" -s $S shell "ls /data/local/tmp/npu_m1/ /data/local/tmp/npu_m1/bin /data/local/tmp/npu_m1/lib 2>/dev/null | head -40; echo ---; getprop ro.product.model; getprop ro.board.platform; cat /sys/class/thermal/thermal_zone*/type 2>/dev/null | head -5"
done
