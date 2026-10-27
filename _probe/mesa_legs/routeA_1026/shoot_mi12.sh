#!/usr/bin/env bash
# [TongYi-Lite 2026-10-27 R-068] 小米12（a730）回插即打：K40 同款回归田克隆（kq 三门 + hangtest）。
# 前置：USB 回插（98fc9410）。目的=a730 跨代数据点 + K40 试验田备份。
# 【R-067 铁律：无 && 长链；每步独立回显；push 后设备端 md5 复验】
set -u
DEV=${1:?usage: shoot_mi12.sh <serial|ip:5555>}
R=/data/local/tmp/mesa_clrt_1026
KIT=/tmp/e41027/kit740
BIN=/tmp/e41027/bin740
A() { adb -s "$DEV" "$@"; }
echo "== [1/6] 验明正身（R-061 铁律：attributing 前必 getprop）"
A shell "getprop ro.product.model; getprop ro.board.platform"
echo "   期望 Xiaomi 12 / (sm8450|kalama 类 a730)"
echo "== [2/6] tree"
A shell "mkdir -p $R/bin $R/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/aarch64-linux-gnu $R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt $R/usr/share/khronos/opencl $R/tmp $R/out $R/stage_1030"
echo "== [3/6] kit 544MB（lib/opt/usr-share）"
A push $KIT/lib/aarch64-linux-gnu $R/lib/ 2>&1 | tail -1
A push $KIT/lib/ld-linux-aarch64.so.1 $R/lib/ 2>&1 | tail -1
A shell "chmod 755 $R/lib/ld-linux-aarch64.so.1"
A push $KIT/opt/mesa-cl/lib/aarch64-linux-gnu $R/opt/mesa-cl/ 2>&1 | tail -1
A push $KIT/usr/share/khronos $R/usr/share/ 2>&1 | tail -1
echo "== [4/6] 弹药（十库+探针+legs+ling_e2e+gomp+qwen 模型）"
A push $BIN/libggml.so.0.27.0 $BIN/libggml-base.so.0.27.0 $BIN/libggml-cpu.so.0.27.0 $BIN/libggml-opencl.so.0.27.0 $BIN/libllama.so.0.7.0 $BIN/libllama-common.so.0.7.0 $BIN/l3_probe_v22 $BIN/hangtest $R/bin/ 2>&1 | tail -1
A push $BIN/routeA_e4_legs.sh $R/routeA_e4_legs.sh 2>&1 | tail -1
A push /tmp/e41027/ling_e2e_v2 $R/bin/ling_e2e 2>&1 | tail -1
A push /tmp/e41027/libgomp1 $R/lib/aarch64-linux-gnu/libgomp.so.1 2>&1 | tail -1
A shell "mkdir -p /storage/emulated/0/TongYiLite/models"
A push /tmp/e41027/qwen05b.gguf /storage/emulated/0/TongYiLite/models/qwen2.5-0.5b-q4_k_m.gguf 2>&1 | tail -1
echo "== [5/6] chmod + SONAME 六软链（rc=127 教训）+ 设备端 md5 复验"
A shell "cd $R/bin && chmod 755 ling_e2e l3_probe_v22 hangtest minicpm_e2e 2>/dev/null; chmod 755 $R/routeA_e4_legs.sh $R/lib/aarch64-linux-gnu/libgomp.so.1; ln -sf libggml.so.0.27.0 libggml.so.0; ln -sf libggml-base.so.0.27.0 libggml-base.so.0; ln -sf libggml-cpu.so.0.27.0 libggml-cpu.so.0; ln -sf libggml-opencl.so.0.27.0 libggml-opencl.so.0; ln -sf libllama.so.0.7.0 libllama.so.0; ln -sf libllama-common.so.0.7.0 libllama-common.so.0; md5sum libggml-opencl.so.0.27.0 ling_e2e hangtest | cut -c1-8,42-"
echo "   期望 lib=1be75abc(七代 kit 底) ling_e2e=f7b05066 hangtest=ece4af1e"
A push /tmp/e41026/stage_1030_lib.so $R/stage_1030/libggml-opencl.so.0.27.0 2>&1 | tail -1
A shell "md5sum $R/stage_1030/libggml-opencl.so.0.27.0 | cut -c1-8"
echo "   期望 stage=2695a8be"
echo "== [6/6] kq 三门（判据=md5 恒 c89ba51f；性能列仅参考-DVFS 律）+ hangtest"
# 顺序律：kq1 无 cp——必须跑在已 cp 升代的 kq2/kq7 之后（否则 bin=kit 七代底被红卡拒）
A shell "sh $R/routeA_e4_legs.sh kq2" 2>&1 | grep -E "####|tok_s|IDLE"
A shell "sh $R/routeA_e4_legs.sh kq7" 2>&1 | grep -E "####|tok_s"
A shell "sh $R/routeA_e4_legs.sh kq1" 2>&1 | grep -E "####|tok_s"
A shell "export LD_LIBRARY_PATH=$R/bin:$R/lib/aarch64-linux-gnu:$R/lib:$R/opt/mesa-cl/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors RUSTICL_ENABLE=kgsl HOME=$R/tmp XDG_CACHE_HOME=$R/tmp; timeout 120 $R/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 --library-path \$LD_LIBRARY_PATH $R/bin/hangtest; echo HANG_RC=\$?" 2>&1 | grep -E "VERDICT|HANG_RC"
echo "DONE_MI12"
