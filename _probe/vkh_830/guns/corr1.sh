#!/system/bin/sh
# [vkh R-124] 正确性单枪 —— 用户铁律: 单条/短生/NPRED<=8/三查/禁压测
# usage: corr1.sh <tag> <ngl> <npred> <model> [env ...]
LOG=/data/local/tmp/mesa_clrt_1026/out/corr1.log
R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
TAG=$1; NGL=$2; NPRED=$3; MODEL=$4; shift 4
T=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
MEM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
SO=$(settings get global stay_on_while_plugged_in)
echo "#### $TAG gate temp=$T mem=$MEM stayon=$SO $(date +%H:%M:%S)" >> $LOG
if [ "${T:-999999}" -gt 44000 ]; then echo "#### $TAG ABORT_HOT" >> $LOG; exit 1; fi
if [ "$SO" != "0" ]; then settings put global stay_on_while_plugged_in 0; fi
if [ "${MEM:-0}" -lt 7000000 ]; then echo "#### $TAG ABORT_MEM" >> $LOG; exit 1; fi
timeout 900 env GGML_OPENCL_FAKE_QCOM_REQD=1 GGML_CPU_NO_REPACK=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors "$@" \
  $R/lib/ld-linux-aarch64.so.1 --library-path $K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu \
  $K/ling_e2e $MODEL $NPRED $NGL 42 > $R/out/$TAG.tok 2> $R/out/$TAG.err
RC=$?
echo "#### $TAG rc=$RC tokmd5=$(md5sum $R/out/$TAG.tok 2>/dev/null | cut -c1-8) $(date +%H:%M:%S)" >> $LOG
grep -aE 'PHASE' $R/out/$TAG.err | tail -3 >> $LOG
echo "$TAG kcerr=$(grep -ac 'ERROR' $R/out/$TAG.err 2>/dev/null)" >> $LOG
exit $RC
