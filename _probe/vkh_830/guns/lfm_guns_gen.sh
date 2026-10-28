#!/bin/bash
# 生成三杆 LFM/回归枪（醒屏即推）。全 env 块逐字含 FAKE_QCOM（枪律）。
set -e
common_head='R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LGM=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
B4M=/data/local/tmp/g759/qwen35-4b-q4km.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
ENVS="GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors GGML_OPENCL_HOST_TIMING=1"'
# 注: 上面 LP/ENVS 里 $R/$K 要在设备 sh 展开=写单引号进文件
cat > lfm2g.sh <<'EOS'
R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 1700 env GGML_OPENCL_FAKE_QCOM_REQD=1 E2E_LOADONLY=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $M 1 99 42 > $R/out/lfm_lo.tok 2> $R/out/lfm_lo.err
echo "#### LFMRUN rc=$?" > $R/out/lfm_lo.log
grep -aE 'PHASE|CRASH|LOAD_FAIL' $R/out/lfm_lo.err >> $R/out/lfm_lo.log
grep -ac 'kernel compile error' $R/out/lfm_lo.err | sed 's/^/kcerr=/' >> $R/out/lfm_lo.log
EOS
cat > lfm3g.sh <<'EOS'
R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 1700 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors GGML_OPENCL_HOST_TIMING=1 GGML_OPENCL_MOE_SELFBUILD=1 GGML_OPENCL_FA_A7X_GUARD=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1 GGML_OPENCL_A7X_LMHEAD_CPU=0 GGML_OPENCL_MOE_VIEW_SLOT=1 GGML_OPENCL_SMART_DRAIN=1 $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $M 32 99 42 > $R/out/lfm_gpu.tok 2> $R/out/lfm_gpu.err
echo "#### LFMGPU rc=$? tokmd5=$(md5sum $R/out/lfm_gpu.tok | cut -c1-8)" > $R/out/lfm_gpu.log
grep -aE 'METRIC|CRASH|DECODE_FAIL|PREFILL_FAIL|GATE-FAIL' $R/out/lfm_gpu.err | tail -6 >> $R/out/lfm_gpu.log
grep -ac 'kernel compile error' $R/out/lfm_gpu.err | sed 's/^/kcerr=/' >> $R/out/lfm_gpu.log
tail -c 200 $R/out/lfm_gpu.tok >> $R/out/lfm_gpu.log
EOS
cat > lfm4g.sh <<'EOS'
R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 1700 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $M 32 0 42 > $R/out/lfm_cpu.tok 2> $R/out/lfm_cpu.err
echo "#### LFMCPU rc=$? tokmd5=$(md5sum $R/out/lfm_cpu.tok | cut -c1-8)" > $R/out/lfm_cpu.log
grep -aE 'METRIC|CRASH|FAIL' $R/out/lfm_cpu.err | tail -4 >> $R/out/lfm_cpu.log
tail -c 200 $R/out/lfm_cpu.tok >> $R/out/lfm_cpu.log
EOS
cat > l15g.sh <<'EOS'
R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
LGM=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 900 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors GGML_OPENCL_HOST_TIMING=1 GGML_OPENCL_MOE_SELFBUILD=1 GGML_OPENCL_FA_A7X_GUARD=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1 GGML_OPENCL_A7X_LMHEAD_CPU=0 GGML_OPENCL_SMART_DRAIN=1 $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $LGM 32 99 42 > $R/out/l15.tok 2> $R/out/l15.err
echo "#### L15 rc=$? tokmd5=$(md5sum $R/out/l15.tok | cut -c1-8)" > $R/out/l15.log
grep -aE 'METRIC|CRASH|FAIL' $R/out/l15.err | tail -3 >> $R/out/l15.log
EOS
wc -l lfm2g.sh lfm3g.sh lfm4g.sh l15g.sh
