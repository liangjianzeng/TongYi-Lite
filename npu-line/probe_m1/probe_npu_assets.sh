#!/system/bin/sh
# NPU M1 设备资产探针（只读，无 root 需求）
# 用法：adb push probe_npu_assets.sh /data/local/tmp/npu_m1/ && adb shell sh /data/local/tmp/npu_m1/probe_npu_assets.sh
# 注意：本文件必须 LF 结尾（CRLF 陷阱，见项目 AGENTS.md）
echo "== soc"
getprop ro.soc.model
getprop ro.soc.manufacturer
getprop ro.board.platform
getprop ro.product.model
getprop ro.build.version.release
echo "== vendor qnn/snpe/htp libs"
ls /vendor/lib64 | grep -i -e qnn -e snpe -e htp
echo "== public.libraries.txt (qnn/htp/snpe 可被 app dlopen 的判断依据)"
grep -i -e qnn -e htp -e snpe /vendor/etc/public.libraries.txt 2>/dev/null
echo "== hexagon devices"
ls -l /dev | grep -i -e fastrpc -e adsprpc -e cdsp
echo "== dsp dirs"
ls /vendor/dsp 2>/dev/null
ls /vendor/dsp/cdsp 2>/dev/null | head -5
echo "== battery (dumpsys, 无 root 功耗协议数据源)"
dumpsys battery | grep -i -e level -e voltage -e counter -e temperature
echo "== thermal"
dumpsys thermalservice 2>/dev/null | grep -i -e mStatus -e Temperature | head -8
echo "== done"
