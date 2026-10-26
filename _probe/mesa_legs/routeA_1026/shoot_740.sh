#!/usr/bin/env bash
# [TongYi-Lite 2026-10-27] 740（xiaomi-13 / Adreno 740，支持底线机型）全 GPU 卸载移植部署。
# 前置：740 adbd 已起（USB 主机跑 scripts\adb-wifi.ps1 后 `adb connect <ip>:5555` 可达）。
# 步骤：目录树 → 七件套 → mesa/clrt/ICD/loader → legs/probe → stage（WBW/IDLE 七代）→ 模型体检（缺则报缺不自动拉 13GB）。
# 判读基线：q740（fl1 async16 ×3 无补丁）→ 740 是否复现 H2′；g49 腿测治愈；金标准以 740 自己的 q0a0 为准。
set -u
DEV=${1:?usage: shoot_740.sh <ip:5555>}
R=/data/local/tmp/mesa_clrt_1026
S=/tmp/e41026
A() { adb -s "$DEV" "$@"; }
echo "== [1/6] tree"
A shell "mkdir -p $R/bin $R/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt $R/usr/share/khronos/opencl $R/tmp $R/out $R/stage_1027"
echo "== [2/6] seven-piece + legs + probes"
A push $S/bin 2>/dev/null || true   # 若本地有整包 bin 目录则整推，否则逐件：
for f in minicpm_e2e libggml-base.so.0.27.0 libggml.so.0.27.0 libggml-cpu.so.0.27.0 libllama.so.0.27.0 libllama-common.so.0.27.0 libggml-opencl.so.0.27.0 libRusticlOpenCL.so.1 l3_coherency_probe_v22 l3_probe_v3; do
  [ -f "$S/$f" ] && A push "$S/$f" "$R/bin/$f" >/dev/null && echo "  pushed $f"
done
echo "== [3/6] runtime libs + mesa + loader（从 chroot overlay 抽，如本机无缓存先 scp）"
A push $S/clrt-overlay/lib $R/lib/ 2>/dev/null || echo "  WARN: clrt-overlay 本机缓存缺失——需从 DGX chroot 重抽（见 R-046 流程）"
echo "== [4/6] stage 七代（WBW+IDLE）"
A push $S/stage_1027/libggml-opencl.so.0.27.0 $R/stage_1027/ >/dev/null && echo "  stage ok"
A push _probe/mesa_legs/routeA_1026/routeA_e4_legs.sh $R/routeA_e4_legs.sh >/dev/null && echo "  legs ok"
echo "== [5/6] 指纹门"
A shell "md5sum $R/bin/minicpm_e2e $R/bin/libggml-opencl.so.0.27.0 2>/dev/null"
echo "   期望: e2e=04aaa77f*  opencl(部署后)=134bfd9c*（g49 腿换 1be75abc）"
echo "== [6/6] 模型体检（不自动推 13GB experts，缺则列出）"
A shell "for f in minicpm-v4.7-35b-a3b-les.gguf minicpm-v4.7-35b-a3b-les.experts minicpm-v4.7-35b-a3b-les.dspark.gguf; do ls -d /storage/emulated/0/TongYiLite/models/\$f >/dev/null 2>&1 && echo HAVE_\$f || echo MISSING_\$f; done"
echo "DONE_740_KIT"
