#!/usr/bin/env bash
# [1027 射击队列] 设备回线后 host 侧一键编排。断点续跑：完成一腿 touch /tmp/e41026/done_<tag>。
# 用法: bash shoot_1027.sh            # 全自动串腿
set -u
D=100.75.247.55:5555
R=/data/local/tmp/mesa_clrt_1026
L=/tmp/e41026
LOG=$L/recovery_logs; mkdir -p "$LOG"
DEV() { timeout 12 adb connect $D >/dev/null 2>&1; timeout 8 adb devices | grep -q "100.75.*device" && return 0 || return 1; }
SH() { adb -s $D shell "$@"; }
leg_done() { [ -f "$L/done_$1" ]; }
mark() { touch "$L/done_$1"; echo "#### DONE $1"; }

DEV || { echo "NO_DEVICE"; exit 1; }

if ! leg_done stage; then
  # 0) 现场清理 + 推送
  SH "pgrep -f minicpm_e2e | xargs -r kill -9" ; sleep 2
  SH "md5sum $R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt/libRusticlOpenCL.so.1.0.0" | tee "$LOG/endorsed_md5.txt"
  adb -s $D push $L/stage_1027/. $R/stage_1027/ >/dev/null
  adb -s $D push $L/shim/libtylgrp_glibc_v8.so $R/bin/libtylgrp.so >/dev/null
  adb -s $D push $L/l3_coherency_probe_1027 $R/bin/l3_coherency_probe >/dev/null
  adb -s $D push $L/libRusticl_e4r16_1026.so $R/stage_1027/libRusticl_e4r16_1026.so >/dev/null
  adb -s $D push /home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/mesa_legs/routeA_1026/routeA_e4_legs.sh $R/routeA_e4_legs.sh >/dev/null
  # 部署七件（备份先行 + SONAME 软链）
  SH "mkdir -p $R/bin_bak_1027 && for f in minicpm_e2e libggml-opencl.so.0.27.0 libggml-base.so.0.27.0 libggml.so.0.27.0 libggml-cpu.so.0.27.0 libllama.so.0.7.0 libllama-common.so.0.7.0; do cp -n $R/bin/\$f $R/bin_bak_1027/ 2>/dev/null; cp $R/stage_1027/\$f $R/bin/\$f; done && for l in libggml.so.0 libggml-base.so.0 libggml-cpu.so.0 libggml-opencl.so.0 libllama.so.0 libllama-common.so.0; do ln -sf \$l.7.0 $R/bin/\$l 2>/dev/null; true; done && ln -sf libggml.so.0.27.0 $R/bin/libggml.so.0 && ln -sf libggml-base.so.0.27.0 $R/bin/libggml-base.so.0 && ln -sf libggml-cpu.so.0.27.0 $R/bin/libggml-cpu.so.0 && ln -sf libggml-opencl.so.0.27.0 $R/bin/libggml-opencl.so.0 && ln -sf libllama.so.0.7.0 $R/bin/libllama.so.0 && ln -sf libllama-common.so.0.7.0 $R/bin/libllama-common.so.0 && md5sum $R/bin/minicpm_e2e $R/bin/libggml-opencl.so.0.27.0 $R/bin/libggml-base.so.0.27.0" 2>&1 | tee "$LOG/deploy.txt"
  # 指纹门：错指纹即停（04aaa77f/134bfd9c/914cc424）
  grep -q 04aaa77f "$LOG/deploy.txt" || { echo "STAGE_FAIL e2e md5"; exit 2; }
  mark stage
fi

run_leg_case() {
  local tag=$1
  leg_done "$tag" && { echo "skip $tag"; return 0; }
  DEV || { echo "LOST_DEVICE before $tag"; exit 3; }
  echo "======== LEG $tag $(date +%H:%M:%S) ========"
  SH "sh $R/routeA_e4_legs.sh $tag" > "$LOG/$tag.log" 2>&1
  local rc=$?
  tail -25 "$LOG/$tag.log"
  if grep -qE "ABORT_THERMAL|LOST" "$LOG/$tag.log"; then echo "HALT: thermal/lost at $tag"; exit 4; fi
  mark "$tag"
}

for c in g28 g29 g30 g31 g32 l0a l0b l3a l3b g33 g34; do run_leg_case "$c"; done
# 队列尾检查：影子必须已撤（g30 自撤失败即红牌）
SH "ls $R/bin/libRusticlOpenCL.so.1" 2>/dev/null | grep -q libRusticl && { echo "HALT: shadow left behind!"; exit 5; } || echo "shadow_clear OK"
echo "ALL_LEGS_DONE $(date +%H:%M:%S)"
