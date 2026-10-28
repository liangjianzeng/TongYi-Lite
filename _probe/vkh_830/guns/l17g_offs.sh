R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
LGM=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 900 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors GGML_OPENCL_HOST_TIMING=1 GGML_OPENCL_MOE_SELFBUILD=1 GGML_OPENCL_FA_A7X_GUARD=0 GGML_OPENCL_MESA_LARGE_N_GEMV=1 GGML_OPENCL_A7X_LMHEAD_CPU=0 GGML_OPENCL_SMART_DRAIN=1 GGML_CL_OFFS_DEBUG=1 GGML_OPENCL_RSS_COPY_READBACK=1 $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $LGM 32 99 42 > $R/out/l17.tok 2> $R/out/l17.err
echo "#### L17 rc=$? tokmd5=$(md5sum $R/out/l17.tok | cut -c1-8)" > $R/out/l17.log
grep -ac 'offs-gr' $R/out/l17.err | sed 's/^/offsgr_lines=/' >> $R/out/l17.log
grep -aE 'METRIC|CRASH|FAIL' $R/out/l17.err | tail -3 >> $R/out/l17.log
grep -a 'offs-gr' $R/out/l17.err | head -120 > $R/out/l17_offsgr.txt
