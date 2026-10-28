R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 1700 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors GGML_OPENCL_HOST_TIMING=1 GGML_OPENCL_MOE_SELFBUILD=1 GGML_OPENCL_FA_A7X_GUARD=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1 GGML_OPENCL_A7X_LMHEAD_CPU=0 GGML_OPENCL_MOE_VIEW_SLOT=1 GGML_OPENCL_SMART_DRAIN=1 $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $M 32 99 42 > $R/out/lfm_gpu.tok 2> $R/out/lfm_gpu.err
echo "#### LFMGPU rc=$? tokmd5=$(md5sum $R/out/lfm_gpu.tok | cut -c1-8)" > $R/out/lfm_gpu.log
grep -aE 'METRIC|CRASH|DECODE_FAIL|PREFILL_FAIL|GATE-FAIL' $R/out/lfm_gpu.err | tail -6 >> $R/out/lfm_gpu.log
grep -ac 'kernel compile error' $R/out/lfm_gpu.err | sed 's/^/kcerr=/' >> $R/out/lfm_gpu.log
tail -c 200 $R/out/lfm_gpu.tok >> $R/out/lfm_gpu.log
