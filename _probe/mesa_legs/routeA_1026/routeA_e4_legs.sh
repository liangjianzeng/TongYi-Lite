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
  TAG=$1; FL=$2; NPRED=$3; EXTRAENV=$4; PRELOAD=$5
  # [教训 1026] LD_PRELOAD 绝不 export：会毒死 timeout/grep 等 bionic 二进制
  # （"CANNOT LINK EXECUTABLE timeout: cannot find verneed..."），只在 exec 行 env 注入
  mkdir -p $R/tmp $R/out
  TEMP=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  echo "#### $TAG $(date -Iseconds) loadavg=$(cat /proc/loadavg) temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
  # [热纪律 1026] 温度>44°C（tenths 单位）拒跑热腿，防 21:0x adbd 猝死事件重演
  if [ "${TEMP:-0}" -gt 440 ]; then echo "#### ABORT_THERMAL temp_tenths=$TEMP (>440)"; return 1; fi
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
  if [ "$PRELOAD" != "" ]; then
    PLENV="LD_PRELOAD=$PRELOAD"
  else
    PLENV=""
  fi
  # shellcheck disable=SC2086
  timeout 600 env $PLENV $LOADER --library-path $LP $R/bin/minicpm_e2e \
    $MODEL $EXPERTS 99 $NPRED 512 \
    > $R/out/$TAG.out 2> $R/out/$TAG.err
  echo "#### rc=$? tokbytes=$(ls -l $R/out/$TAG.tok 2>/dev/null | awk '{print $5}')"
  echo "#### tok md5=$(md5sum $R/out/$TAG.tok 2>/dev/null)"
  echo "#### KGSLSUBMIT=$(grep -ac 'KGSLSUBMIT cmd\[' $R/out/$TAG.err)"
  echo "#### driver=$(grep -a 'OpenCL driver:' $R/out/$TAG.err | head -1)"
  echo "#### health=$(grep -acE '造纸|印刷|指南针|火药' $R/out/$TAG.out)"
  echo "#### E4MERGE=$(grep -ac '^E4MERGE' $R/out/$TAG.err) E4DEL=$(grep -ac '^E4DEL' $R/out/$TAG.err) E4BO=$(grep -ac '^E4BO' $R/out/$TAG.err) E4FENCE=$(grep -ac '^E4FENCE' $R/out/$TAG.err) E4HIST=$(grep -ac '^E4HIST' $R/out/$TAG.err)"
  echo "#### E4VERIFY=$(grep -ac '^E4VERIFY' $R/out/$TAG.err) VERIFY_MISMATCH=$(grep -ac 'MISMATCH' $R/out/$TAG.err) E4REUSE=$(grep -ac '^E4REUSE' $R/out/$TAG.err) REUSE_NOTRET=$(grep -acE 'E4REUSE .*reached=0' $R/out/$TAG.err) E4FAST=$(grep -ac '^E4FAST' $R/out/$TAG.err) FASTHIT=$(grep -ac 'hit=1' $R/out/$TAG.err)"
  echo "#### E4BOREL=$(grep -ac '^E4BOREL' $R/out/$TAG.err) E4BOREUSE=$(grep -ac '^E4BOREUSE' $R/out/$TAG.err) BOREUSE_NOTRET=$(grep -acE 'E4BOREUSE .*reached=0' $R/out/$TAG.err) FASTRK0=$(grep -acE '^E4FAST.* hit=1 rk=0' $R/out/$TAG.err) FASTRK1=$(grep -acE '^E4FAST.* hit=1 rk=1' $R/out/$TAG.err)"
  echo "#### E4FLUSH=$(grep -ac '^E4FLUSH' $R/out/$TAG.err) E4WAIT=$(grep -ac '^E4WAIT' $R/out/$TAG.err) WAIT_NEV_MAX=$(grep -aoE 'E4WAIT wseq=[0-9]+ nev=[0-9]+' $R/out/$TAG.err | awk '{gsub(/nev=/,"",$3); if($3>m)m=$3} END{print m+0}') UNKNOWN_DBG=$(grep -ac 'Unknown RUSTICL_DEBUG flag' $R/out/$TAG.err)"
  echo "#### E4HIST_last=$(grep -a '^E4HIST' $R/out/$TAG.err | tail -1)"
  echo "#### nosub=$(grep -ac 'does not support subgroups' $R/out/$TAG.err) drop=$(grep -ac 'drop unsupported device' $R/out/$TAG.err)"
  echo "#### E4LAG=$(grep -ac '^E4LAG' $R/out/$TAG.err) LAG_MAX=$(grep -aoE 'lag=-?[0-9]+' $R/out/$TAG.err | awk '{gsub(/lag=/,"",$1); if($1>m)m=$1; s+=$1; n++} END{print m+0\" avg=\"(n?s/n:0)}') E4CACHEBAD=$(grep -ac '^E4CACHEBAD' $R/out/$TAG.err)"
  echo "#### E4CB0=$(grep -ac '^E4CB0' $R/out/$TAG.err) E4PREP=$(grep -ac '^E4PREP' $R/out/$TAG.err) E4DEFER_d1=$(grep -acE '^E4DEFER .*defer=1' $R/out/$TAG.err) E4DEFER_d0=$(grep -acE '^E4DEFER .*defer=0' $R/out/$TAG.err)"
  echo "#### E4GRELPAIR=$(grep -ac '^E4GRELPAIR' $R/out/$TAG.err) E4GPOL_last=$(grep -a '^E4GPOL' $R/out/$TAG.err | tail -1)"
}

case "$1" in
  e4a) # diag 库 async NPRED=16：复现乱码 + 采 E4 统计（预期 health=0，tok≠金标准）
    run_leg e4a_async "" 16 "TYL_E4=1"
    ;;
  e4b) # diag 库 OPFLUSH=1 NPRED=48：对照腿（预期 tok=e9b88e56 逐字节全等）
    run_leg e4b_fl1 "GGML_OPENCL_OPFLUSH=1" 48 "TYL_E4=1"
    ;;
  e4c) # 背书库（影子须已撤）async + MESA_DEBUG=sync NPRED=8：E1 复判（旧，env 名错已定案）
    run_leg e4c_sync "" 8 "MESA_DEBUG=sync"
    ;;
  e4d) # 0032 diag2 async NPRED=16：R10 判决主腿（E4REUSE reached=0 事件 = 在飞 IB 覆写窗口打开）
    run_leg e4d_async2 "" 16 "TYL_E4=1"
    ;;
  e4e) # 0032 diag2 OPFLUSH=1 NPRED=48：对照腿（预期 tok=e9b88e56 逐字节全等）
    run_leg e4e_fl12 "GGML_OPENCL_OPFLUSH=1" 48 "TYL_E4=1"
    ;;
  e4f) # 阳性对照：RUSTICL_DEBUG=__tyl_probe__（err 须现 Unknown RUSTICL_DEBUG flag）
    run_leg e4f_probe "" 8 "RUSTICL_DEBUG=__tyl_probe__ TYL_E4=1"
    ;;
  e4g) # 真 E1：async NPRED=8 + RUSTICL_DEBUG=sync（判据=E4WAIT nev 分布趋 1）
    run_leg e4g_sync2 "" 8 "RUSTICL_DEBUG=sync TYL_E4=1"
    ;;
  e4h) # 0034 diag4 鉴别腿：async NPRED=16 + TYL_E4_NOFAST=1（wait 全走 KMD；health=1 ⇒ 快路早完成定罪）
    run_leg e4h_nofast "" 16 "TYL_E4=1 TYL_E4_NOFAST=1"
    ;;
  flscan) # [背书库 1026] OPFLUSH 阈值扫（回档自设备侧 sed 演化版，恢复全列表）：N≤2 对 / N≥3 乱
    for N in 1 2 4 8 16 32; do run_leg flscan$N "" 48 "GGML_OPENCL_OPFLUSH=$N TYL_E4=1"; done
    ;;
  fl2a) # fl2 专项：OPFLUSH=2 NPRED=48（三连金标准 leg-058/059 复测形态；diag7 下即 fl2b）
    run_leg fl2a_48 "" 48 "GGML_OPENCL_OPFLUSH=2 TYL_E4=1"
    ;;
  g7) # diag7 三腿之一：async 16 + grp 垫片（E4LAG/E4CACHEBAD + 垫片 E4GRELPAIR 联合判决）
    run_leg e4d_g7 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  fix8) # diag8 修复验证：async 16 + TYL_UPSZ=4MB（cb0 环绕假说的因果判据：health=1 ⇒ 定罪+修复闭环）
    run_leg e4d_fix8 "" 16 "TYL_E4=1 TYL_UPSZ=4194304"
    ;;
  fix8g) # diag8 双探针腿：修复验证 + grp 垫片同开（环绕应消失）
    run_leg e4d_fix8g "" 16 "TYL_E4=1 TYL_UPSZ=4194304 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  g11) # fl1 治愈对照（全代探针在场，验证不扰动金标准）
    run_leg e4f_g11 "" 1 "TYL_E4=1"
    ;;
  g17) # 日程对照：fl1 金标准 + 全内核打点
    run_leg e4f_g17 "" 1 "TYL_E4=1"
    ;;
  g16) # 0046 生死括号版内核普查：async 16 + E4
    run_leg e4d_g16 "" 16 "TYL_E4=1"
    ;;
  g24) # 治愈剂量扫描：async 16 + 写前 usleep 500us
    run_leg e4d_g24 "" 16 "TYL_E4=1 TYL_E4_GRP=4 TYL_GRP_SLEEPUS=500" "$R/bin/libtylgrp.so"
    ;;
  g27) # 解耦：背书库 + GRP=4 无 TYL_E4（纯 sleep，零打印）
    run_leg e4d_g27 "" 16 "TYL_E4_GRP=4"
    ;;
  g26) # ★产品化终验：背书库 + 垫片v7 写前 2ms（无 NOMERGE 代码参与）
    run_leg e4d_g26 "" 16 "TYL_E4_GRP=4" "$R/bin/libtylgrp.so"
    ;;
  g25) # 治愈剂量扫描：async 16 + 写前 usleep 100us
    run_leg e4d_g25 "" 16 "TYL_E4=1 TYL_E4_GRP=4 TYL_GRP_SLEEPUS=100" "$R/bin/libtylgrp.so"
    ;;
  g23) # H2′ 时延假说：async 16 + 垫片v6（≥1MB 写前 usleep 2ms，GRP=4）
    run_leg e4d_g23 "" 16 "TYL_E4=1 TYL_E4_GRP=4" "$R/bin/libtylgrp.so"
    ;;
  g22) # Mesa 自证：async 16 + E4 + NOMERGE（每 submit 单独 ioctl，无垫片）
    run_leg e4d_g22 "" 16 "TYL_E4=1 TYL_E4_NOMERGE=1"
    ;;
  g21) # kernel 竞态二分：async 16 + 垫片v5（仅 NDRange 后 finish，GRP=3）
    run_leg e4d_g21 "" 16 "TYL_E4=1 TYL_E4_GRP=3" "$R/bin/libtylgrp.so"
    ;;
  g20) # 同二进制金标准：fl1 原生 16 token（无垫片）
    run_leg e4d_g20 "1" 16 ""
    ;;
  g19) # fl1-by-shim：async 16 + 垫片v4（每 op 后 clFinish，GRP=2）
    run_leg e4d_g19 "" 16 "TYL_E4=1 TYL_E4_GRP=2" "$R/bin/libtylgrp.so"
    ;;
  g18) # S1′ 治愈点定位：async 16 + 垫片v3（>1MB 写后注入 clFinish）
    run_leg e4d_g18 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  g15) # 内核参数级普查：async 16 + E4（E4KHDR/E4KARG/E4R2BO/id=）
    run_leg e4d_g15 "" 16 "TYL_E4=1"
    ;;
  g14) # host 写审计腿：async 16 + 垫片 v2（map/unmap/read/write 全参）
    run_leg e4d_g14 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  g12) # fastpath 神罪腿：async 16 + TYL_E4_NOFAST=1（等待全走 KMD）
    run_leg e4d_g12 "" 16 "TYL_E4=1 TYL_E4_NOFAST=1"
    ;;
  g13) # 对照：async 16 无 NOFAST（同 diag 快慢分歧复现）
    run_leg e4d_g13 "" 16 "TYL_E4=1"
    ;;
  g9) # diag9 乒乓全采腿：async 16 + grp 垫片 + Rusticl E4GMEM 三点（NEW/REL/DROP 身份贯通）
    run_leg e4d_g9 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  *) echo "usage: sh routeA_e4_legs.sh e4a|...|e4h|flscan|fl2a|g7|fix8|fix8g"; exit 2;;
esac
