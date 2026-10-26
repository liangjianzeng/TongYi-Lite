#!/system/bin/sh
# [E4 插桩轮 1026] routeA 路 A 三条腿（L-A diag async / L-B diag OPFLUSH=1 / L-C 背书 MESA_DEBUG=sync）
# 逐字复用 routeA_legs_1026.sh q0a0 段形态：LP 四目录/OCL_ICD_VENDORS/RUSTICL_ENABLE=kgsl/
# 字面 env 同行导出/E2E 协议逐字/timeout 保护。影子库=$R/bin/libRusticlOpenCL.so.1（LP bin 首位）。
R=/data/local/tmp/mesa_clrt_1026
LP=/data/local/tmp/mesa_clrt_1026/bin:/data/local/tmp/mesa_clrt_1026/lib/aarch64-linux-gnu:/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/lib/aarch64-linux-gnu
LOADER=/data/local/tmp/mesa_clrt_1026/lib/ld-linux-aarch64.so.1
ICD=/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/etc/OpenCL/vendors
MODEL=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
EXPERTS=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'

run_leg () {
  TAG=$1; FL=$2; NPRED=$3; EXTRAENV=$4
  mkdir -p $R/tmp $R/out
  echo "#### $TAG $(date -Iseconds) loadavg=$(cat /proc/loadavg) temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
  echo "#### shadow=$(ls -la $R/bin/libRusticlOpenCL.so.1 2>/dev/null | awk '{print $5}')"
  # Android mksh: 裸 VAR=值 被当命令 → 一律 export（§6-4 铁律的可靠形态）
  export LD_LIBRARY_PATH=$LP
  export OCL_ICD_VENDORS=$ICD
  export RUSTICL_ENABLE=kgsl
  export HOME=/data/local/tmp/mesa_clrt_1026/tmp
  export XDG_CACHE_HOME=/data/local/tmp/mesa_clrt_1026/tmp
  export GGML_OPENCL_MESA_SPIRV=1
  export GGML_OPENCL_ADRENO_XMEM_GEMM=0
  export GGML_OPENCL_FAKE_QCOM_REQD=1
  if [ "$FL" != "" ]; then export GGML_OPENCL_OPFLUSH=1; else unset GGML_OPENCL_OPFLUSH; fi
  if [ "$EXTRAENV" != "" ]; then export $EXTRAENV; fi
  export E2E_NBATCH=512
  export E2E_SEED=42
  export E2E_TEMP=0
  export E2E_NOMMAP=1
  export E2E_TOKDUMP=$R/out/$TAG.tok
  export GGML_E2E_PROMPT="$PROMPT"
  timeout 600 $LOADER --library-path $LP $R/bin/minicpm_e2e \
    $MODEL $EXPERTS 99 $NPRED 512 \
    > $R/out/$TAG.out 2> $R/out/$TAG.err
  echo "#### rc=$? tokbytes=$(ls -l $R/out/$TAG.tok 2>/dev/null | awk '{print $5}')"
  echo "#### tok md5=$(md5sum $R/out/$TAG.tok 2>/dev/null)"
  echo "#### KGSLSUBMIT=$(grep -ac 'KGSLSUBMIT cmd\[' $R/out/$TAG.err)"
  echo "#### driver=$(grep -a 'OpenCL driver:' $R/out/$TAG.err | head -1)"
  echo "#### health=$(grep -acE '造纸|印刷|指南针|火药' $R/out/$TAG.out)"
  echo "#### E4MERGE=$(grep -ac '^E4MERGE' $R/out/$TAG.err) E4DEL=$(grep -ac '^E4DEL' $R/out/$TAG.err) E4BO=$(grep -ac '^E4BO' $R/out/$TAG.err) E4FENCE=$(grep -ac '^E4FENCE' $R/out/$TAG.err) E4HIST=$(grep -ac '^E4HIST' $R/out/$TAG.err)"
  echo "#### E4HIST_last=$(grep -a '^E4HIST' $R/out/$TAG.err | tail -1)"
  echo "#### nosub=$(grep -ac 'does not support subgroups' $R/out/$TAG.err) drop=$(grep -ac 'drop unsupported device' $R/out/$TAG.err)"
}

case "$1" in
  e4a) # diag 库 async NPRED=16：复现乱码 + 采 E4 统计（预期 health=0，tok≠金标准）
    run_leg e4a_async "" 16 "TYL_E4=1"
    ;;
  e4b) # diag 库 OPFLUSH=1 NPRED=48：对照腿（预期 tok=e9b88e56 逐字节全等）
    run_leg e4b_fl1 "GGML_OPENCL_OPFLUSH=1" 48 "TYL_E4=1"
    ;;
  e4c) # 背书库（影子须已撤）async + MESA_DEBUG=sync NPRED=8：E1 复判
    run_leg e4c_sync "" 8 "MESA_DEBUG=sync"
    ;;
  *) echo "usage: sh routeA_e4_legs.sh e4a|e4b|e4c"; exit 2;;
esac
