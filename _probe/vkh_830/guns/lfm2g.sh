R=/data/local/tmp/mesa_clrt_1026
K=/data/local/tmp/vkh_lfm2
M=/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf
LP=$K:$R/bin/patch79e:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
timeout 1700 env GGML_OPENCL_FAKE_QCOM_REQD=1 E2E_LOADONLY=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp RUSTICL_ENABLE=kgsl OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors $R/lib/ld-linux-aarch64.so.1 --library-path $LP $K/ling_e2e $M 1 99 42 > $R/out/lfm_lo.tok 2> $R/out/lfm_lo.err
echo "#### LFMRUN rc=$?" > $R/out/lfm_lo.log
grep -aE 'PHASE|CRASH|LOAD_FAIL' $R/out/lfm_lo.err >> $R/out/lfm_lo.log
grep -ac 'kernel compile error' $R/out/lfm_lo.err | sed 's/^/kcerr=/' >> $R/out/lfm_lo.log
