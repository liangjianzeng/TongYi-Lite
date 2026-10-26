#!/system/bin/sh
# [C1 S0 路 A 上机腿 · 2026-10-26] clrt/glibc 第二运行时三背书（主线亲自，README §3.2/3.3）
# 铁律：路径一律字面绝对路径（同行赋值不导出）；禁注 ALLOW_NO_SUBGROUP（能力旁路=判据作废）；
#       FAKE_QCOM_REQD=1 必注（R-011 generic 约定：内核走 Adreno 分支+core CL3.0 shuffle，
#       REQD 属性退化 no-op；run_p3_ablate:64 自判双开关全关的 q0a0=CPU 回退同义反复不算数）；
#       性能/数值腿只认 stdout [e2e][METRIC]；driver 串必须真 Mesa（QUALCOMM 串=vendor，作废）。
R=/data/local/tmp/mesa_clrt_1026
LP=/data/local/tmp/mesa_clrt_1026/bin:/data/local/tmp/mesa_clrt_1026/lib/aarch64-linux-gnu:/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/lib/aarch64-linux-gnu
LOADER=/data/local/tmp/mesa_clrt_1026/lib/ld-linux-aarch64.so.1
ICD=/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/etc/OpenCL/vendors

case "$1" in
  clinfo)
    LD_LIBRARY_PATH=$LP OCL_ICD_VENDORS=$ICD timeout 60 $LOADER --library-path $LP /data/local/tmp/mesa_clrt_1026/usr/bin/clinfo
    ;;
  probe)
    LD_LIBRARY_PATH=$LP OCL_ICD_VENDORS=$ICD timeout 60 $LOADER --library-path $LP /data/local/tmp/mesa_clrt_1026/bin/cl_subgroup_probe
    ;;
  hangtest)
    LD_LIBRARY_PATH=$LP OCL_ICD_VENDORS=$ICD timeout 90 $LOADER --library-path $LP /data/local/tmp/mesa_clrt_1026/bin/cl_subgroup_hangtest
    ;;
  q0a0)
    mkdir -p /data/local/tmp/mesa_clrt_1026/tmp /data/local/tmp/mesa_clrt_1026/out
    echo "#### q0a0 $(date -Iseconds) loadavg=$(cat /proc/loadavg) temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
    echo "#### baseline md5: $(md5sum /data/local/tmp/s5_off_fl1b/MESA_FLUSH1_r1.tok)"
    LD_LIBRARY_PATH=$LP OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl \
    HOME=/data/local/tmp/mesa_clrt_1026/tmp XDG_CACHE_HOME=/data/local/tmp/mesa_clrt_1026/tmp \
    GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0 GGML_OPENCL_OPFLUSH=1 \
    GGML_OPENCL_FAKE_QCOM_REQD=1 \
    E2E_NBATCH=512 E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1 \
    E2E_TOKDUMP=/data/local/tmp/mesa_clrt_1026/out/q0a0.tok \
    GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结' \
    timeout 600 $LOADER --library-path $LP /data/local/tmp/mesa_clrt_1026/bin/minicpm_e2e \
      /storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf \
      /storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts 99 48 512 \
      > /data/local/tmp/mesa_clrt_1026/out/q0a0.out 2> /data/local/tmp/mesa_clrt_1026/out/q0a0.err
    echo "#### rc=$? tokbytes=$(ls -l /data/local/tmp/mesa_clrt_1026/out/q0a0.tok 2>/dev/null | awk '{print $5}')"
    echo "#### tok md5=$(md5sum /data/local/tmp/mesa_clrt_1026/out/q0a0.tok 2>/dev/null)"
    echo "#### KGSLSUBMIT=$(grep -ac 'KGSLSUBMIT cmd\[' /data/local/tmp/mesa_clrt_1026/out/q0a0.err)"
    echo "#### drop=$(grep -ac 'drop unsupported device' /data/local/tmp/mesa_clrt_1026/out/q0a0.err)"
    echo "#### nosub=$(grep -ac 'does not support subgroups' /data/local/tmp/mesa_clrt_1026/out/q0a0.err)"
    echo "#### driver=$(grep -a 'OpenCL driver:' /data/local/tmp/mesa_clrt_1026/out/q0a0.err | head -1)"
    echo "#### health=$(grep -acE '造纸|印刷|指南针|火药' /data/local/tmp/mesa_clrt_1026/out/q0a0.out)"
    ;;
  *) echo "usage: sh routeA_legs.sh clinfo|probe|hangtest|q0a0"; exit 2;;
esac
