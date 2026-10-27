#!/usr/bin/env bash
# [TongYi-Lite 2026-10-27] 740（xiaomi-13 / Adreno 740，支持底线）免模型部署 + 探针五关。
# 前置：740 adbd 起（USB 主机 scripts\adb-wifi.ps1 或 adb tcpip 5555）。35B 模型晚点由用户传入（experts 13GB 唯一副本在 830！）。
# 弹药（本回合已预置完毕，勿改路径）：
#   /tmp/e41027/bin740/  = 七件套(04aaa77f/914cc424/7329a949/d3d7df1b/aecefbd3/92726af7/1be75abc) + l3_probe_v22(e2cee291) + hangtest(ece4af1e) + legs 脚本
#   /tmp/e41027/stage_1030_lib.so = 十代 2695a8be（g49 形腿备弹）；kit740/usr/bin/clinfo（v3 补推送）
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
echo "== [3/6] ten-piece + probe + legs + clinfo + stage_1030"
A push $BIN/. $R/bin/ >/dev/null && A shell "mv $R/bin/routeA_e4_legs.sh $R/ 2>/dev/null; chmod 755 $R/bin/minicpm_e2e $R/bin/l3_probe_v22 $R/bin/hangtest $R/routeA_e4_legs.sh $R/lib/ld-linux-aarch64.so.1 $R/usr/bin/clinfo; cd $R/bin; ln -sf libggml.so.0.27.0 libggml.so.0; ln -sf libggml-base.so.0.27.0 libggml-base.so.0; ln -sf libggml-cpu.so.0.27.0 libggml-cpu.so.0; ln -sf libggml-opencl.so.0.27.0 libggml-opencl.so.0; ln -sf libllama.so.0.7.0 libllama.so.0; ln -sf libllama-common.so.0.7.0 libllama-common.so.0 2>/dev/null; true"
A shell "mkdir -p $R/usr/bin" && A push $KIT/usr/bin/clinfo $R/usr/bin/clinfo >/dev/null && A shell "chmod 755 $R/usr/bin/clinfo"
A shell "mkdir -p $R/stage_1030" && A push /tmp/e41026/stage_1030_lib.so $R/stage_1030/libggml-opencl.so.0.27.0 >/dev/null && echo "  clinfo+stage_1030 ok"
echo "== [4/5] 指纹门（不符即停）"
A shell "md5sum $R/bin/minicpm_e2e $R/bin/libggml-opencl.so.0.27.0 $R/bin/l3_probe_v22" | cut -c1-9,42-
echo "   期望 04aaa77f* / 1be75abc* / e2cee291*"
echo "== [5/6] 探针五关双型（a740 驱动共性 = L3 跨代判据）"
A shell "sh $R/routeA_e4_legs.sh l3b3 0" 2>&1 | grep -E "PROBE2|probe3_rc"
A shell "sh $R/routeA_e4_legs.sh l3b3 1" 2>&1 | grep -E "PROBE2|probe3_rc"
echo "== 模型体检（缺则等用户传入，勿自行拉 13GB）"
A shell "for f in minicpm-v4.7-35b-a3b-les.gguf minicpm-v4.7-35b-a3b-les.experts minicpm-v4.7-35b-a3b-les.dspark.gguf; do ls -d /storage/emulated/0/TongYiLite/models/\$f >/dev/null 2>&1 && echo HAVE_\$f || echo MISSING_\$f; done"
echo "== [6/6] clinfo IFP 行 + hangtest（dlopen 工具=LP 必含 opt/mesa-cl 双路，ledger135 铁律）"
A shell "export LD_LIBRARY_PATH=$R/bin:$R/lib/aarch64-linux-gnu:$R/lib:$R/opt/mesa-cl/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors RUSTICL_ENABLE=kgsl HOME=$R/tmp XDG_CACHE_HOME=$R/tmp; $R/usr/bin/clinfo 2>/dev/null | grep -iE 'driver_version|OpenCL driver|SUBGROUP|PREFERRED' | head -8; timeout 120 $R/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 --library-path \$LD_LIBRARY_PATH $R/bin/hangtest; echo HANG_RC=\$?"
echo "DONE_740_KIT"
