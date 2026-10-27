#!/usr/bin/env bash
# [TongYi-Lite 2026-10-27] 740（xiaomi-13 / Adreno 740，支持底线）免模型部署 + 探针五关。
# 前置：740 adbd 起（USB 主机 scripts\adb-wifi.ps1 或 adb tcpip 5555）。35B 模型晚点由用户传入（experts 13GB 唯一副本在 830！）。
# 弹药（本回合已预置完毕，勿改路径）：
#   /tmp/e41027/bin740/  = 七件套(04aaa77f/914cc424/7329a949/d3d7df1b/aecefbd3/92726af7/1be75abc) + l3_probe_v22(e2cee291) + legs 脚本
#   /tmp/e41027/kit740/{lib,opt,usr} = 运行时树镜像（544MB，从 830 抽）
set -u
DEV=${1:?usage: shoot_740.sh <ip:5555|serial>}
R=/data/local/tmp/mesa_clrt_1026
KIT=/tmp/e41027/kit740
BIN=/tmp/e41027/bin740
A() { adb -s "$DEV" "$@"; }
echo "== [1/5] tree"
A shell "mkdir -p $R/bin $R/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt $R/usr/share/khronos/opencl $R/tmp $R/out $R/stage_1027"
echo "== [2/5] runtime tree (544MB, ~2-4min)"
A push $KIT/lib/aarch64-linux-gnu $R/lib/ >/dev/null && echo "  lib ok"
A push $KIT/opt/mesa-cl/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/ >/dev/null && echo "  mesa/clrt ok"
A push $KIT/usr/share/khronos $R/usr/share/ >/dev/null && echo "  ICD ok"
echo "== [3/5] seven-piece + probe + legs"
A push $BIN/. $R/bin/ >/dev/null && A shell "mv $R/bin/routeA_e4_legs.sh $R/ 2>/dev/null; chmod 755 $R/bin/minicpm_e2e $R/bin/l3_probe_v22 $R/routeA_e4_legs.sh 2>/dev/null; true"
echo "== [4/5] 指纹门（不符即停）"
A shell "md5sum $R/bin/minicpm_e2e $R/bin/libggml-opencl.so.0.27.0 $R/bin/l3_probe_v22" | cut -c1-9,42-
echo "   期望 04aaa77f* / 1be75abc* / e2cee291*"
echo "== [5/5] 探针五关双型（a740 驱动共性 = L3 跨代判据）"
A shell "sh $R/routeA_e4_legs.sh l3b3 0" 2>&1 | grep -E "PROBE2|probe3_rc"
A shell "sh $R/routeA_e4_legs.sh l3b3 1" 2>&1 | grep -E "PROBE2|probe3_rc"
echo "== 模型体检（缺则等用户传入，勿自行拉 13GB）"
A shell "for f in minicpm-v4.7-35b-a3b-les.gguf minicpm-v4.7-35b-a3b-les.experts minicpm-v4.7-35b-a3b-les.dspark.gguf; do ls -d /storage/emulated/0/TongYiLite/models/\$f >/dev/null 2>&1 && echo HAVE_\$f || echo MISSING_\$f; done"
echo "DONE_740_KIT"
